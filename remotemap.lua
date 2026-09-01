local DataStorage = require("datastorage")
local util = require("util")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local RemoteMap = {}

local function getRelativePath(home_dir, current_path)
    if not home_dir or not current_path then return nil end

    local h_clean = home_dir:gsub("/+$", "")
    local c_clean = current_path:gsub("/+$", "")

    -- 1. Match unresolved paths first
    if c_clean == h_clean then
        return ""
    end
    if c_clean:sub(1, #h_clean + 1) == h_clean .. "/" then
        return c_clean:sub(#h_clean + 2)
    end

    -- 2. Try matching resolved paths
    local ffiUtil = require("ffi/util")
    local realpath = ffiUtil.original_realpath or ffiUtil.realpath
    local home = realpath(home_dir) or home_dir
    local curr = realpath(current_path)
    if not curr then
        local parent, name = current_path:match("(.*)/(.*)")
        if parent then
            local real_parent = realpath(parent)
            if real_parent then
                curr = real_parent .. "/" .. name
            end
        end
    end
    curr = curr or current_path

    home = home:gsub("/+$", "")
    curr = curr:gsub("/+$", "")

    if curr == home then
        return ""
    end
    if curr:sub(1, #home + 1) == home .. "/" then
        return curr:sub(#home + 2)
    end

    return nil
end

local function getNodeForRelativePath(map, rel_path)
    if not map then return nil end
    if rel_path == "" then
        return map
    end
    local node = map
    for part in rel_path:gmatch("[^/]+") do
        if node.folders then
            local next_node = node.folders[part .. "/"] or node.folders[part]
            if next_node then
                node = next_node
            else
                return nil
            end
        else
            return nil
        end
    end
    return node
end

local function serializeTable(tbl, indent)
    indent = indent or ""
    local parts = {}
    table.insert(parts, "{\n")
    local next_indent = indent .. "    "

    if tbl.files and #tbl.files > 0 then
        table.insert(parts, next_indent .. "files = {\n")
        for _, file in ipairs(tbl.files) do
            table.insert(parts, next_indent .. "    {\n")
            table.insert(parts, string.format("%s        name = %q,\n", next_indent, file.name))
            table.insert(parts, string.format("%s        url = %q,\n", next_indent, file.url))
            if file.filesize then
                table.insert(parts, string.format("%s        filesize = %d,\n", next_indent, file.filesize))
            end
            if file.modification then
                table.insert(parts, string.format("%s        modification = %d,\n", next_indent, file.modification))
            end
            table.insert(parts, next_indent .. "    },\n")
        end
        table.insert(parts, next_indent .. "},\n")
    else
        table.insert(parts, next_indent .. "files = {},\n")
    end

    table.insert(parts, next_indent .. "folders = {\n")
    if tbl.folders then
        for folder_name, sub_tbl in pairs(tbl.folders) do
            table.insert(parts, string.format("%s    [%q] = %s", next_indent, folder_name, serializeTable(sub_tbl, next_indent)))
            table.insert(parts, ",\n")
        end
    end
    table.insert(parts, next_indent .. "},\n")

    table.insert(parts, indent .. "}")
    return table.concat(parts)
end

local _cached_map = nil

local function loadMap()
    if _cached_map then
        return _cached_map
    end
    local map_file_path = DataStorage:getSettingsDir() .. "/remotelibrary_map.lua"
    if util.fileExists(map_file_path) then
        local ok, res = pcall(dofile, map_file_path)
        if ok then
            _cached_map = res
            return _cached_map
        else
            logger.warn("[RemoteLibrary] Failed to load map:", res)
        end
    end
    return nil
end

local function getVirtualAttributes(map, rel_path)
    rel_path = rel_path:gsub("/+$", "")

    -- Check if it is a directory
    local node = getNodeForRelativePath(map, rel_path)
    if node then
        return {
            mode = "directory",
            size = 0,
            modification = os.time(),
            access = os.time(),
            change = os.time(),
        }
    end

    -- Check if it is a file
    local parent_path, target_name = rel_path:match("(.*)/(.*)")
    if not parent_path then
        parent_path = ""
        target_name = rel_path
    end

    local parent_node = getNodeForRelativePath(map, parent_path)
    if parent_node and parent_node.files then
        for _, file in ipairs(parent_node.files) do
            if file.name == target_name then
                return {
                    mode = "file",
                    size = file.filesize or 0,
                    modification = file.modification or os.time(),
                    access = file.modification or os.time(),
                    change = file.modification or os.time(),
                    url = file.url,
                }
            end
        end
    end

    return nil
end

-- Same "where does this path sit relative to home_dir" question resolveProxy
-- answers internally; exposed for callers with no proxy-detection need of
-- their own (e.g. deciding whether to scaffold a physical directory).
function RemoteMap.getRelativePath(home_dir, path)
    return getRelativePath(home_dir, path)
end

function RemoteMap.invalidate()
    _cached_map = nil
end

-- Persists tree as the remote map and invalidates the read cache; the two
-- are always done together, so save() folds invalidation in rather than
-- leaving callers to remember to pair them.
function RemoteMap.save(tree)
    local map_file_path = DataStorage:getSettingsDir() .. "/remotelibrary_map.lua"
    local file = io.open(map_file_path, "w")
    if file then
        file:write("return " .. serializeTable(tree) .. "\n")
        file:close()
        RemoteMap.invalidate()
        return true
    end
    return false
end

-- Resolves path to proxy metadata, or nil if it isn't a proxy. A path that
-- physically exists on disk is never a proxy, even if the remote map has a
-- stale entry for it.
function RemoteMap.resolveProxy(home_dir, path)
    if not home_dir or not path then return nil end
    if lfs.original_attributes(path, "mode") then
        return nil
    end
    local rel_path = getRelativePath(home_dir, path)
    if not rel_path then return nil end
    local map = loadMap()
    if not map then return nil end
    return getVirtualAttributes(map, rel_path)
end

-- Bulk listing of dir_path's virtual children (raw map contents: folder
-- names and file records), or nil if dir_path isn't a mapped directory.
function RemoteMap.listChildren(home_dir, dir_path)
    if not home_dir or not dir_path then return nil end
    local rel_path = getRelativePath(home_dir, dir_path)
    if not rel_path then return nil end
    local map = loadMap()
    if not map then return nil end
    local node = getNodeForRelativePath(map, rel_path)
    if not node then return nil end
    return node.folders or {}, node.files or {}
end

return RemoteMap
