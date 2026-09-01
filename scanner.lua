local UIManager = require("ui/uimanager")
local util = require("util")
local ffiUtil = require("ffi/util")
local DocumentRegistry = require("document/documentregistry")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local logger = require("logger")

local Scanner = {}

local function trimSlashes(s)
    local from = s:match("^/*()")
    return from > #s and "" or s:match(".*[^/]", from)
end

local function rtrimSlashes(s)
    local n = #s
    while n > 0 and s:find("^/", n) do
        n = n - 1
    end
    return s:sub(1, n)
end

--[[--
Attempts to fetch the entire remote WebDAV subtree in a single request via
`PROPFIND` with `Depth: infinity`, instead of the one-request-per-folder
crawl. Not all WebDAV servers support infinite depth (some return 403, some
silently cap it), so any failure here should fall back to the regular crawl.

Returns the populated tree, folder_count, file_count on success, or nil on
any failure (caller falls back to the per-folder crawl).
--]]--
local function tryWebDavDeepScan(cloudstorage_dir)
    local address = cloudstorage_dir.address
    if not address then return nil end

    local root_path = trimSlashes(cloudstorage_dir.url or "")
    local base_address = rtrimSlashes(address)
    local request_url = base_address .. "/" .. util.urlEncode(root_path, "/")
    if request_url:sub(-1) ~= "/" then
        request_url = request_url .. "/"
    end
    local request_url_path = trimSlashes(util.urlDecode(request_url:match("^https?://[^/]*(.*)$") or request_url))

    local sink = {}
    local data = [[<?xml version="1.0"?><a:propfind xmlns:a="DAV:"><a:prop><a:resourcetype/><a:getcontentlength/><a:getlastmodified/></a:prop></a:propfind>]]
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local ok, code, headers, status = pcall(function()
        return socket.skip(1, http.request{
            url      = request_url,
            method   = "PROPFIND",
            headers  = {
                ["Content-Type"]   = "application/xml",
                ["Depth"]          = "infinity",
                ["Content-Length"] = #data,
            },
            user     = cloudstorage_dir.username,
            password = cloudstorage_dir.password,
            source   = ltn12.source.string(data),
            sink     = ltn12.sink.table(sink),
        })
    end)
    socketutil:reset_timeout()

    if not ok or not headers or not code or code < 200 or code > 299 then
        logger.dbg("[RemoteLibrary] Depth:infinity PROPFIND failed, falling back to per-folder crawl:", status or code)
        return nil
    end

    local res = table.concat(sink)
    if res == "" then return nil end

    local show_unsupported = G_reader_settings:isTrue("show_unsupported")
    local entries = {}
    for item in res:gmatch("<[^:]*:response[^>]*>(.-)</[^:]*:response>") do
        local item_fullpath = util.urlDecode(item:match("<[^:]*:href[^>]*>(.*)</[^:]*:href>"))
        if item_fullpath then
            local item_path = trimSlashes(item_fullpath)
            if item_path ~= request_url_path then
                local item_name = ffiUtil.basename(util.htmlEntitiesToUtf8(item_fullpath))
                local is_not_collection = item:find("<[^:]*:resourcetype%s*/>") or
                                          item:find("<[^:]*:resourcetype></[^:]*:resourcetype>")
                if is_not_collection then
                    if show_unsupported or DocumentRegistry:hasProvider(item_name) then
                        table.insert(entries, {
                            path = item_path,
                            is_file = true,
                            name = item_name,
                            filesize = tonumber(item:match("<[^:]*:getcontentlength[^>]*>(%d+)</[^:]*:getcontentlength>")),
                        })
                    end
                elseif item:find("<[^:]*:collection[^<]*/>") then
                    table.insert(entries, {
                        path = item_path,
                        is_folder = true,
                        name = item_name,
                    })
                end
            end
        end
    end

    -- Sort by path depth so parent folders are always created before their children.
    table.sort(entries, function(a, b)
        local depth_a, depth_b = select(2, a.path:gsub("/", "")), select(2, b.path:gsub("/", ""))
        return depth_a < depth_b
    end)

    local root_node = { files = {}, folders = {} }
    local prefix = request_url_path == "" and "" or (request_url_path .. "/")
    local folder_count = 0
    local file_count = 0

    for _, entry in ipairs(entries) do
        local relative = entry.path
        if prefix ~= "" then
            if relative:sub(1, #prefix) ~= prefix then
                relative = nil -- outside of the scanned root, skip
            else
                relative = relative:sub(#prefix + 1)
            end
        end
        if relative and relative ~= "" then
            local node = root_node
            local segments = {}
            for segment in relative:gmatch("[^/]+") do
                table.insert(segments, segment)
            end
            local last_index = entry.is_file and (#segments - 1) or #segments
            for i = 1, last_index do
                local seg = segments[i]
                node.folders[seg] = node.folders[seg] or { files = {}, folders = {} }
                node = node.folders[seg]
            end
            if entry.is_file then
                table.insert(node.files, {
                    name = entry.name,
                    url = entry.path,
                    filesize = entry.filesize,
                })
                file_count = file_count + 1
            else
                folder_count = folder_count + 1
            end
        end
    end

    return root_node, folder_count, file_count
end

--[[--
Scans a configured cloud-storage provider and builds a remote-map tree.

Tries the WebDAV Depth:infinity fast path first (when applicable), falling
back to a per-folder crawl. Reports progress via `callbacks.on_progress(
folder_count, file_count)` and terminates via `callbacks.on_done(tree,
folder_count, file_count, cancelled)`.

`should_cancel()` is polled at each crawl tick and before the scan starts;
once the WebDAV deep-scan's single PROPFIND request is in flight it can't be
interrupted, matching the crawl's own per-request granularity.
--]]--
function Scanner.scan(provider, cloudstorage_dir, callbacks, should_cancel)
    provider.base = cloudstorage_dir

    local root_node = { files = {}, folders = {} }
    local queue = { { url = cloudstorage_dir.url, node = root_node } }
    local folder_count = 0
    local file_count = 0

    local function finish(tree, cancelled)
        callbacks.on_done(tree, folder_count, file_count, cancelled)
    end

    local function processQueue()
        if should_cancel() then
            finish(root_node, true)
            return
        end

        if #queue == 0 then
            finish(root_node, false)
            return
        end

        local current = table.remove(queue, 1)
        callbacks.on_progress(folder_count, file_count)

        provider.run(function()
            local items = provider.listFolder(current.url, true)
            if items then
                for _, item in ipairs(items) do
                    if item.is_file then
                        table.insert(current.node.files, {
                            name = item.text,
                            url = item.url,
                            filesize = item.filesize,
                            modification = item.modification,
                        })
                        file_count = file_count + 1
                    elseif item.is_folder then
                        current.node.folders[item.text] = { files = {}, folders = {} }
                        table.insert(queue, {
                            url = item.url,
                            node = current.node.folders[item.text]
                        })
                        folder_count = folder_count + 1
                    end
                end
            end
            UIManager:nextTick(processQueue)
        end)
    end

    if should_cancel() then
        finish(root_node, true)
        return
    end

    if cloudstorage_dir.type == "webdav" and cloudstorage_dir.address then
        local ok, tree, deep_folder_count, deep_file_count = pcall(tryWebDavDeepScan, cloudstorage_dir)
        if ok and tree then
            folder_count = deep_folder_count
            file_count = deep_file_count
            finish(tree, false)
            return
        end
    end

    processQueue()
end

return Scanner
