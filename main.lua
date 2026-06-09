--[[--
RemoteLibrary plugin allows browsing and reading files from a remote library server.

@module koplugin.RemoteLibrary
--]]--

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local ProgressbarDialog = require("ui/widget/progressbardialog")
local ConfirmBox = require("ui/widget/confirmbox")
local _ = require("gettext")
local BD = require("ui/bidi")
local Device = require("device")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local logger = require("logger")

local RemoteLibrary = WidgetContainer:extend{
    name = "remotelibrary",
    is_doc_only = false,
    settings_file = DataStorage:getSettingsDir() .. "/remotelibrary.lua",
    settings = nil,
    updated = nil,
}

local function canonicalizePath(path)
    if not path then return nil end
    local is_absolute = path:sub(1, 1) == "/"
    local segments = {}
    for segment in path:gmatch("[^/]+") do
        if segment == "." then
            -- do nothing
        elseif segment == ".." then
            if #segments > 0 and segments[#segments] ~= ".." then
                table.remove(segments)
            else
                if not is_absolute then
                    table.insert(segments, "..")
                end
            end
        else
            table.insert(segments, segment)
        end
    end
    local res = table.concat(segments, "/")
    if is_absolute then
        return "/" .. res
    else
        return res
    end
end

local function makePhysicalPath(path)
    local lfs = require("libs/libkoreader-lfs")
    local attributes = lfs.original_attributes or lfs.attributes

    if attributes(path, "mode") == "directory" then
        return true
    end

    local components
    if path:sub(1, 1) == "/" then
        components = "/"
    else
        components = ""
    end

    local success, err
    for component in path:gmatch("([^/]+)") do
        components = components .. component .. "/"
        if attributes(components, "mode") == nil then
            success, err = lfs.mkdir(components)
            if not success then
                return nil, err
            end
        end
    end

    return success, err
end

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

local _cached_map = nil

local function getRemoteLibraryMap()
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
                }
            end
        end
    end

    return nil
end

function RemoteLibrary:init()
    self.ui.menu:registerToMainMenu(self)

    -- Hook ffi/util realpath globally
    local ffiUtil = require("ffi/util")
    if not ffiUtil._remotelibrary_patched then
        ffiUtil._remotelibrary_patched = true
        logger.info("[RemoteLibrary] Patching ffi/util realpath")
        local original_realpath = ffiUtil.realpath
        ffiUtil.original_realpath = original_realpath
        ffiUtil.realpath = function(path)
            if not path then return nil end
            path = canonicalizePath(path)
            local resolved = original_realpath(path)
            if resolved then
                return resolved
            end
            local hdir = G_reader_settings:readSetting("home_dir") or Device.home_dir
            if not hdir then return nil end
            local rel_path = getRelativePath(hdir, path)
            if not rel_path then return nil end
            local map = getRemoteLibraryMap()
            if not map then return nil end
            if not getVirtualAttributes(map, rel_path) then return nil end
            local parts = {}
            local current = path
            local resolved_base = nil
            while current and current ~= "" and current ~= "/" do
                local parent, name = current:match("(.*)/(.*)")
                if not parent then
                    name = current
                    parent = ""
                end
                table.insert(parts, 1, name)
                resolved_base = original_realpath(parent == "" and "/" or parent)
                if resolved_base then break end
                current = parent
            end
            if resolved_base then
                resolved_base = resolved_base:gsub("/+$", "")
                return resolved_base .. "/" .. table.concat(parts, "/")
            end
            return path
        end
    end

    -- Hook libs/libkoreader-lfs globally to make virtual files visible to Bookshelf/KOReader
    local lfs = require("libs/libkoreader-lfs")
    if not lfs._remotelibrary_patched then
        lfs._remotelibrary_patched = true
        logger.info("[RemoteLibrary] Patching libs/libkoreader-lfs")
        local original_dir = lfs.dir
        local original_attributes = lfs.attributes

        lfs.original_dir = original_dir
        lfs.original_attributes = original_attributes

        lfs.dir = function(path)
            local hdir = G_reader_settings:readSetting("home_dir") or Device.home_dir
            if not hdir then
                return original_dir(path)
            end

            local rel_path = getRelativePath(hdir, path)
            if not rel_path then
                return original_dir(path)
            end

            local map = getRemoteLibraryMap()
            if not map then
                return original_dir(path)
            end

            local node = getNodeForRelativePath(map, rel_path)
            if not node then
                return original_dir(path)
            end

            -- Collect all local items first (if the directory exists)
            local local_items = {}
            local ok_dir, iter, dir_obj = pcall(original_dir, path)
            if ok_dir and iter then
                for entry in iter, dir_obj do
                    if entry ~= "." and entry ~= ".." then
                        local_items[entry] = true
                    end
                end
            end

            -- Collect all virtual items (not already in local_items)
            local virtual_items = {}
            
            -- Overlay folders
            if node.folders then
                for folder_name, _ in pairs(node.folders) do
                    local clean_name = folder_name:gsub("/+$", "")
                    if not local_items[clean_name] then
                        table.insert(virtual_items, clean_name)
                    end
                end
            end

            -- Overlay files
            if node.files then
                for _, file in ipairs(node.files) do
                    if not local_items[file.name] then
                        table.insert(virtual_items, file.name)
                    end
                end
            end

            -- If there are no virtual items, return the original iterator
            if #virtual_items == 0 then
                return original_dir(path)
            end

            -- Construct combined list of entries
            local all_entries = { ".", ".." }
            for item, _ in pairs(local_items) do
                table.insert(all_entries, item)
            end
            for _, item in ipairs(virtual_items) do
                table.insert(all_entries, item)
            end

            local idx = 0
            local custom_iterator = function()
                idx = idx + 1
                return all_entries[idx]
            end

            local dummy_dir_obj = {
                close = function() end
            }

            return custom_iterator, dummy_dir_obj
        end

        lfs.attributes = function(path, request)
            -- First, check if the real file/directory exists on disk
            local real_res
            if request then
                real_res = original_attributes(path, request)
            else
                real_res = original_attributes(path)
            end

            if real_res ~= nil then
                return real_res
            end

            -- Otherwise, see if it is a virtual path in our RemoteLibrary map
            local hdir = G_reader_settings:readSetting("home_dir") or Device.home_dir
            if not hdir then
                return nil
            end

            local rel_path = getRelativePath(hdir, path)
            if not rel_path then
                return nil
            end

            local map = getRemoteLibraryMap()
            if not map then
                return nil
            end

            local virtual_attr = getVirtualAttributes(map, rel_path)
            if not virtual_attr then
                return nil
            end

            if request then
                return virtual_attr[request]
            else
                return virtual_attr
            end
        end
    end

    -- Hook ReaderUI:showReader globally to intercept opening virtual books and download them first
    local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok_reader and ReaderUI and not ReaderUI._remotelibrary_patched then
        ReaderUI._remotelibrary_patched = true
        logger.info("[RemoteLibrary] Patching ReaderUI:showReader")
        local original_showReader = ReaderUI.showReader
        ReaderUI.showReader = function(r_self, file, provider, seamless, is_provider_forced, after_open_callback)
            local hdir = G_reader_settings:readSetting("home_dir") or Device.home_dir
            if hdir then
                local rel_path = getRelativePath(hdir, file)
                if rel_path then
                    -- Let's see if the file exists on disk
                    local exists_on_disk = lfs.original_attributes(file, "mode") == "file"
                    if not exists_on_disk then
                        -- Check if it exists in the remote map
                        local map = getRemoteLibraryMap()
                        if map then
                            local parent_path, target_name = rel_path:match("(.*)/(.*)")
                            if not parent_path then
                                parent_path = ""
                                target_name = rel_path
                            end
                            local parent_node = getNodeForRelativePath(map, parent_path)
                            if parent_node and parent_node.files then
                                local matched_file
                                for _, f in ipairs(parent_node.files) do
                                    if f.name == target_name then
                                        matched_file = f
                                        break
                                    end
                                end
                                if matched_file then
                                    -- It is a virtual proxy file! Prompt download and then open!
                                    local item = {
                                        text = "[Cloud] " .. target_name,
                                        path = file,
                                        is_proxy = true,
                                        is_file = true,
                                        url = matched_file.url,
                                        filesize = matched_file.filesize,
                                        modification = matched_file.modification,
                                    }
                                    UIManager:show(ConfirmBox:new{
                                        text = string.format(_("Would you like to download %s?"), target_name),
                                        ok_text = _("Download"),
                                        cancel_text = _("Cancel"),
                                        ok_callback = function()
                                            self:downloadRemoteFile(item, function(success)
                                                if success then
                                                    original_showReader(r_self, file, provider, seamless, is_provider_forced, after_open_callback)
                                                end
                                            end)
                                        end,
                                    })
                                    return
                                end
                            end
                        end
                    end
                end
            end
            return original_showReader(r_self, file, provider, seamless, is_provider_forced, after_open_callback)
        end
    end

    -- Hook FileChooser init to intercept FileChooser instantiation before first getList
    local FileChooser = require("ui/widget/filechooser")
    if not FileChooser._init_remotelibrary_patched then
        FileChooser._init_remotelibrary_patched = true
        local original_init = FileChooser.init
        FileChooser.init = function(fc_self)
            local plugin = fc_self.ui and (fc_self.ui.RemoteLibrary or fc_self.ui.remotelibrary)
            if plugin then
                plugin:hookFileChooser(fc_self)
            end
            original_init(fc_self)
        end
    end

    -- Hook BookInfo:getDocProps to prevent opening non-existent proxy files
    local BookInfo = require("apps/filemanager/filemanagerbookinfo")
    if not BookInfo._remotelibrary_patched then
        BookInfo._remotelibrary_patched = true
        logger.info("[RemoteLibrary] Patching BookInfo:getDocProps")
        local original_getDocProps = BookInfo.getDocProps
        BookInfo.getDocProps = function(bi_self, file, book_props, no_open_document)
            local hdir = G_reader_settings:readSetting("home_dir") or Device.home_dir
            if hdir then
                local rel_path = getRelativePath(hdir, file)
                if rel_path and lfs.original_attributes(file, "mode") ~= "file" then
                    logger.info("[RemoteLibrary] BookInfo:getDocProps intercepted proxy:", file)
                    return BookInfo.extendProps(nil, file)
                end
            end
            return original_getDocProps(bi_self, file, book_props, no_open_document)
        end
    end

    -- Hook BookInfoManager:getBookInfo and getDocProps to handle remote proxy files
    local ok, BookInfoManager = pcall(require, "bookinfomanager")
    if ok and BookInfoManager and not BookInfoManager._remotelibrary_patched then
        BookInfoManager._remotelibrary_patched = true
        logger.info("[RemoteLibrary] Patching BookInfoManager:getBookInfo and getDocProps")
        local original_getBookInfo = BookInfoManager.getBookInfo
        BookInfoManager.getBookInfo = function(bim_self, filepath, get_cover)
            local hdir = G_reader_settings:readSetting("home_dir") or Device.home_dir
            if hdir then
                local rel_path = getRelativePath(hdir, filepath)
                if rel_path and lfs.original_attributes(filepath, "mode") ~= "file" then
                    logger.info("[RemoteLibrary] BookInfoManager:getBookInfo intercepted proxy:", filepath)
                    local directory, filename = util.splitFilePathName(filepath)
                    local clean_filename = filename:gsub("^%[Cloud%]%s*", "")
                    local filename_without_suffix = filemanagerutil.splitFileNameType(clean_filename)
                    return {
                        directory = directory,
                        filename = filename,
                        in_progress = 0,
                        cover_fetched = "Y",
                        has_meta = true,
                        has_cover = nil,
                        ignore_meta = false,
                        ignore_cover = "Y",
                        title = filename_without_suffix,
                        authors = _("[Cloud]"),
                        _is_directory = false,
                        _no_provider = true
                    }
                end
            end
            return original_getBookInfo(bim_self, filepath, get_cover)
        end

        local original_bim_getDocProps = BookInfoManager.getDocProps
        BookInfoManager.getDocProps = function(bim_self, filepath)
            local hdir = G_reader_settings:readSetting("home_dir") or Device.home_dir
            if hdir then
                local rel_path = getRelativePath(hdir, filepath)
                if rel_path and lfs.original_attributes(filepath, "mode") ~= "file" then
                    logger.info("[RemoteLibrary] BookInfoManager:getDocProps intercepted proxy:", filepath)
                    return BookInfo.extendProps(nil, filepath)
                end
            end
            return original_bim_getDocProps(bim_self, filepath)
        end
    end

    -- Hook FileManager setupLayout to intercept FileChooser
    local FileManager = require("apps/filemanager/filemanager")
    if not FileManager._setupLayout_remotelibrary_patched then
        FileManager._setupLayout_remotelibrary_patched = true
        local original_setupLayout = FileManager.setupLayout
        FileManager.setupLayout = function(fm_self)
            original_setupLayout(fm_self)
            local plugin = fm_self.RemoteLibrary or fm_self.remotelibrary
            if plugin then
                plugin:hookFileChooser(fm_self.file_chooser)
            end
        end
    end

    -- If file_chooser is already created, hook it now!
    if self.ui.file_chooser then
        self:hookFileChooser(self.ui.file_chooser)
    end
end

function RemoteLibrary:hookFileChooser(fc)
    local home_dir = G_reader_settings:readSetting("home_dir") or Device.home_dir
    logger.info("[RemoteLibrary] hookFileChooser called, home_dir:", home_dir)
    if not home_dir then return end

    if not fc._remotelibrary_patched then
        fc._remotelibrary_patched = true

        local original_getList = fc.getList
        fc.getList = function(fc_self, path, collate)
            local dirs, files = original_getList(fc_self, path, collate)

            -- Load the map
            local map = getRemoteLibraryMap()
            if not map then
                return dirs, files
            end

            -- Check if path is under home_dir
            local rel_path = getRelativePath(home_dir, path)
            if not rel_path then
                return dirs, files
            end

            -- Traverse remote map
            local node = getNodeForRelativePath(map, rel_path)
            if not node then
                return dirs, files
            end

            -- Post-process dirs to tag virtual ones with [Cloud]
            for _, d in ipairs(dirs) do
                if type(d) == "table" and d.path then
                    local d_rel = getRelativePath(home_dir, d.path)
                    if d_rel and lfs.original_attributes(d.path, "mode") ~= "directory" then
                        d.is_proxy = true
                        d.is_folder = true
                        if not d.text:find("^%[Cloud%]") then
                            local clean_name = d.text:gsub("/+$", "")
                            d.text = "[Cloud] " .. clean_name .. "/"
                        end
                    end
                end
            end

            -- Post-process files to tag virtual ones with [Cloud] and add url/size metadata
            for _, f in ipairs(files) do
                if type(f) == "table" and f.path then
                    local f_rel = getRelativePath(home_dir, f.path)
                    if f_rel and lfs.original_attributes(f.path, "mode") ~= "file" then
                        f.is_proxy = true
                        f.is_file = true
                        local target_name = f_rel:match("[^/]+$") or f.text
                        if node.files then
                            for _, file in ipairs(node.files) do
                                if file.name == target_name then
                                    f.url = file.url
                                    f.filesize = file.filesize
                                    f.modification = file.modification
                                    f.attr = {
                                        mode = "file",
                                        size = file.filesize,
                                        modification = file.modification,
                                    }
                                    break
                                end
                            end
                        end
                        if not f.text:find("^%[Cloud%]") then
                            f.text = "[Cloud] " .. f.text
                        end
                    end
                end
            end

            return dirs, files
        end

        local original_changeToPath = fc.changeToPath
        fc.changeToPath = function(fc_self, path, focused_path)
            local rel_path = getRelativePath(home_dir, path)
            if rel_path then
                makePhysicalPath(path)
            end
            return original_changeToPath(fc_self, path, focused_path)
        end
    end

    if fc.onFileSelect and fc.onFileSelect ~= fc._remotelibrary_hooked_onFileSelect then
        local original_onFileSelect = fc.onFileSelect
        fc.onFileSelect = function(fc_self, item)
            if item.is_proxy and item.is_file then
                if fc_self.ui and fc_self.ui.selected_files then
                    UIManager:show(InfoMessage:new{
                        text = _("Operations on remote proxy files are not supported in select mode."),
                        timeout = 3,
                    })
                    return true
                else
                    local clean_filename = item.text:gsub("^%[Cloud%]%s*", "")
                    UIManager:show(ConfirmBox:new{
                        text = string.format(_("Would you like to download %s?"), clean_filename),
                        ok_text = _("Download"),
                        cancel_text = _("Cancel"),
                        ok_callback = function()
                            self:downloadAndOpenFile(item)
                        end,
                    })
                    return true
                end
            else
                return original_onFileSelect(fc_self, item)
            end
        end
        fc._remotelibrary_hooked_onFileSelect = fc.onFileSelect
    end

    if fc.showFileDialog and fc.showFileDialog ~= fc._remotelibrary_hooked_showFileDialog then
        local original_showFileDialog = fc.showFileDialog
        fc.showFileDialog = function(fc_self, item)
            if item.is_proxy and item.is_file then
                return true
            else
                return original_showFileDialog(fc_self, item)
            end
        end
        fc._remotelibrary_hooked_showFileDialog = fc.showFileDialog
    end
end

function RemoteLibrary:downloadRemoteFile(item, callback)
    self:loadSettings()
    local cloudstorage_dir = self.settings:readSetting("cloudstorage_dir")
    if not cloudstorage_dir then
        UIManager:show(InfoMessage:new{
            text = _("Please configure the Cloudstorage directory first."),
            timeout = 3,
        })
        if callback then callback(false) end
        return
    end

    local cloudstorage = self.ui.cloudstorage
    if not cloudstorage then
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then
            cloudstorage = FileManager.instance.cloudstorage
        end
    end

    if not cloudstorage then
        UIManager:show(InfoMessage:new{
            text = _("Cloud storage plugin is not enabled or available."),
            timeout = 3,
        })
        if callback then callback(false) end
        return
    end

    cloudstorage:getProviders()
    cloudstorage:loadSettings()

    local provider = cloudstorage.providers[cloudstorage_dir.type]
    if not provider then
        UIManager:show(InfoMessage:new{
            text = _("Cloud storage provider not found."),
            timeout = 3,
        })
        if callback then callback(false) end
        return
    end

    provider.base = cloudstorage_dir

    local progressbar_dialog = ProgressbarDialog:new{
        title = _("Downloading remote file…"),
        subtitle = item.text:gsub("^%[Cloud%]%s*", ""),
        progress_max = item.filesize or 0,
        dismissable = true,
        dismiss_text = _("Do you want to cancel downloading?"),
    }

    local is_cancelled = false
    progressbar_dialog.dismiss_callback = function()
        is_cancelled = true
    end

    progressbar_dialog:show()

    provider.run(function()
        if is_cancelled then
            progressbar_dialog:close()
            if callback then callback(false) end
            return
        end

        local progress_callback = function(progress)
            if not is_cancelled then
                progressbar_dialog:reportProgress(progress)
            end
        end

        logger.info("[RemoteLibrary] Starting download", "URL:", item.url, "local path:", item.path or item.filepath, "provider:", cloudstorage_dir.type)
        -- Ensure parent directory exists
        local target_path = item.path or item.filepath
        local local_dir = target_path:match("(.*)/")
        if local_dir then
            makePhysicalPath(local_dir)
        end

        -- Download
        local code = provider.downloadFile(item.url, target_path, progress_callback)
        logger.info("[RemoteLibrary] Download finished", "code:", code, "file exists:", lfs.original_attributes(target_path, "mode") == "file")
        progressbar_dialog.dismiss_callback = nil
        progressbar_dialog:close()

        if is_cancelled then
            os.remove(target_path)
            if callback then callback(false) end
            return
        end

        if code == 200 then
            -- Refresh file chooser if we are in it
            local fc = self.ui.file_chooser
            if not fc then
                local FileManager = require("apps/filemanager/filemanager")
                if FileManager.instance then
                    fc = FileManager.instance.file_chooser
                end
            end
            if fc then
                fc:refreshPath()
            end
            if callback then callback(true) end
        else
            UIManager:show(InfoMessage:new{
                text = string.format(_("Download failed: %s"), item.text:gsub("^%[Cloud%]%s*", "")),
                timeout = 3,
            })
            if callback then callback(false) end
        end
    end)
end

function RemoteLibrary:downloadAndOpenFile(item)
    self:downloadRemoteFile(item, function(success)
        if success then
            filemanagerutil.openFile(self.ui, item.path or item.filepath)
        end
    end)
end

function RemoteLibrary:loadSettings()
    if self.settings then return end
    self.settings = LuaSettings:open(self.settings_file)
end

function RemoteLibrary:onFlushSettings()
    if self.updated then
        self.settings:flush()
        self.updated = nil
    end
end

function RemoteLibrary:getSettingsSubMenuItems()
    self:loadSettings()
    local cloudstorage_dir = self.settings:readSetting("cloudstorage_dir")
    local text_value
    if cloudstorage_dir then
        text_value = string.format("%s: %s", cloudstorage_dir.name or "", cloudstorage_dir.url or "")
    else
        text_value = _("not set")
    end

    local function openChooser(touchmenu_instance)
        if not self.ui.cloudstorage then
            UIManager:show(InfoMessage:new{
                text = _("Cloud storage plugin is not enabled or available."),
                timeout = 3,
            })
            return
        end
        self.ui.cloudstorage:onShowCloudStorageList(function(server_info)
            self.settings:saveSetting("cloudstorage_dir", server_info)
            self.updated = true
            self:onFlushSettings()
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
        end)
    end

    return {
        {
            text = string.format("%s: %s", _("Cloudstorage directory"), text_value),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                if cloudstorage_dir then
                    local choice_dialog
                    choice_dialog = ButtonDialog:new{
                        title = _("Cloudstorage directory already set") .. "\n\n" .. text_value .. "\n",
                        buttons = {
                            {
                                {
                                    text = _("Change folder"),
                                    callback = function()
                                        UIManager:close(choice_dialog)
                                        openChooser(touchmenu_instance)
                                    end,
                                },
                                {
                                    text = _("Clear setting"),
                                    callback = function()
                                        UIManager:close(choice_dialog)
                                        self.settings:saveSetting("cloudstorage_dir", nil)
                                        self.updated = true
                                        self:onFlushSettings()
                                        if touchmenu_instance then
                                            touchmenu_instance:updateItems()
                                        end
                                    end,
                                },
                            },
                            {
                                {
                                    text = _("Cancel"),
                                    callback = function()
                                        UIManager:close(choice_dialog)
                                    end,
                                },
                            },
                        },
                    }
                    UIManager:show(choice_dialog)
                else
                    openChooser(touchmenu_instance)
                end
            end,
        }
    }
end

function RemoteLibrary:reloadRemoteLibrary()
    self:loadSettings()
    local cloudstorage_dir = self.settings:readSetting("cloudstorage_dir")

    local function openChooser()
        if not self.ui.cloudstorage then
            UIManager:show(InfoMessage:new{
                text = _("Cloud storage plugin is not enabled or available."),
                timeout = 3,
            })
            return
        end
        self.ui.cloudstorage:onShowCloudStorageList(function(server_info)
            self.settings:saveSetting("cloudstorage_dir", server_info)
            self.updated = true
            self:onFlushSettings()
        end)
    end

    if not cloudstorage_dir then
        UIManager:show(InfoMessage:new{
            text = _("Please configure the Cloudstorage directory first."),
            timeout = 3,
        })
        openChooser()
        return
    end

    if not self.ui.cloudstorage then
        UIManager:show(InfoMessage:new{
            text = _("Cloud storage plugin is not enabled or available."),
            timeout = 3,
        })
        return
    end

    self.ui.cloudstorage:getProviders()
    self.ui.cloudstorage:loadSettings()

    local provider = self.ui.cloudstorage.providers[cloudstorage_dir.type]
    if not provider then
        UIManager:show(InfoMessage:new{
            text = _("Cloud storage provider not found."),
            timeout = 3,
        })
        return
    end

    provider.base = cloudstorage_dir

    local is_cancelled = false
    local progressbar_dialog
    progressbar_dialog = ProgressbarDialog:new{
        title = _("Mapping remote library..."),
        subtitle = _("Connecting..."),
        dismissable = true,
        dismiss_text = _("Do you want to cancel scanning?"),
        dismiss_callback = function()
            is_cancelled = true
        end,
    }

    local root_node = { files = {}, folders = {} }
    local queue = { { url = cloudstorage_dir.url, node = root_node } }
    local folder_count = 0
    local file_count = 0

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

    local function saveMap()
        local map_file_path = DataStorage:getSettingsDir() .. "/remotelibrary_map.lua"
        local file = io.open(map_file_path, "w")
        if file then
            file:write("return " .. serializeTable(root_node) .. "\n")
            file:close()
            return true
        end
        return false
    end

    local function processQueue()
        if is_cancelled then
            progressbar_dialog:close()
            return
        end

        if #queue == 0 then
            progressbar_dialog:close()
            saveMap()
            _cached_map = nil
            UIManager:show(InfoMessage:new{
                text = string.format(_("Reload complete: %d folders and %d files mapped."), folder_count, file_count),
                timeout = 4,
            })
            return
        end

        local current = table.remove(queue, 1)

        local progress_text = string.format(_("%d folders, %d files"), folder_count, file_count)
        if progressbar_dialog[1] and progressbar_dialog[1][1] and progressbar_dialog[1][1][2] then
            progressbar_dialog[1][1][2]:setText(progress_text)
            progressbar_dialog:redrawProgressbar()
        end

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

    progressbar_dialog:show()
    UIManager:nextTick(processQueue)
end

function RemoteLibrary:addToMainMenu(menu_items)
    menu_items.remote_library = {
        text = _("Remote Library"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Settings"),
                sub_item_table_func = function()
                    return self:getSettingsSubMenuItems()
                end,
            },
            {
                text = _("Reload"),
                callback = function()
                    self:reloadRemoteLibrary()
                end,
            }
        }
    }
end

return RemoteLibrary

