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

local function getRelativePath(home_dir, current_path)
    local ffiUtil = require("ffi/util")
    local home = ffiUtil.realpath(home_dir) or home_dir
    local curr = ffiUtil.realpath(current_path) or current_path
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

function RemoteLibrary:init()
    self.ui.menu:registerToMainMenu(self)

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
            local home_dir = G_reader_settings:readSetting("home_dir") or Device.home_dir
            if home_dir then
                local rel_path = getRelativePath(home_dir, file)
                if rel_path and lfs.attributes(file, "mode") ~= "file" then
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
            local home_dir = G_reader_settings:readSetting("home_dir") or Device.home_dir
            if home_dir then
                local rel_path = getRelativePath(home_dir, filepath)
                if rel_path and lfs.attributes(filepath, "mode") ~= "file" then
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
            local home_dir = G_reader_settings:readSetting("home_dir") or Device.home_dir
            if home_dir then
                local rel_path = getRelativePath(home_dir, filepath)
                if rel_path and lfs.attributes(filepath, "mode") ~= "file" then
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
            local map_file_path = DataStorage:getSettingsDir() .. "/remotelibrary_map.lua"
            local map_exists = util.fileExists(map_file_path)
            logger.info("[RemoteLibrary] getList path:", path, "collate:", collate ~= nil, "map_exists:", map_exists)
            local map
            if map_exists then
                local ok, res = pcall(dofile, map_file_path)
                if ok then
                    map = res
                else
                    logger.warn("[RemoteLibrary] Failed to load map:", res)
                end
            end

            if not map then
                logger.info("[RemoteLibrary] Map is nil, skipping overlay")
                return dirs, files
            end

            -- Check if path is under home_dir
            local rel_path = getRelativePath(home_dir, path)
            logger.info("[RemoteLibrary] getRelativePath result:", rel_path)
            if not rel_path then
                logger.info("[RemoteLibrary] Path is not under home_dir, skipping overlay")
                return dirs, files
            end

            -- Traverse remote map
            local node = getNodeForRelativePath(map, rel_path)
            logger.info("[RemoteLibrary] getNodeForRelativePath result exists:", node ~= nil)
            if not node then
                return dirs, files
            end

            -- Check existing local items
            local local_exists = {}
            if collate then
                for _, d in ipairs(dirs) do
                    local name = d.text:gsub("/+$", "")
                    local_exists[name] = true
                end
                for _, f in ipairs(files) do
                    local_exists[f.text] = true
                end
            end

            -- Overlay remote folders
            if node.folders then
                for folder_name, _ in pairs(node.folders) do
                    local folder_name_clean = folder_name:gsub("/+$", "")
                    local exists = false
                    if collate then
                        exists = local_exists[folder_name_clean]
                    else
                        exists = lfs.attributes(path .. "/" .. folder_name_clean) ~= nil
                    end

                    if not exists then
                        if collate then
                            local fullpath = path .. "/" .. folder_name_clean
                            local item = {
                                text = "[Cloud] " .. folder_name_clean .. "/",
                                path = fullpath,
                                is_proxy = true,
                                is_folder = true,
                                attr = { mode = "directory" },
                                bidi_wrap_func = BD.directory,
                            }
                            item.mandatory = fc_self:getMenuItemMandatory(item)
                            table.insert(dirs, item)
                        else
                            table.insert(dirs, true)
                        end
                    end
                end
            end

            -- Overlay remote files
            if node.files then
                for _, file in ipairs(node.files) do
                    local exists = false
                    if collate then
                        exists = local_exists[file.name]
                    else
                        exists = lfs.attributes(path .. "/" .. file.name) ~= nil
                    end

                    if not exists then
                        if collate then
                            local fullpath = path .. "/" .. file.name
                            local item = {
                                text = "[Cloud] " .. file.name,
                                path = fullpath,
                                is_proxy = true,
                                is_file = true,
                                url = file.url,
                                filesize = file.filesize,
                                modification = file.modification,
                                attr = {
                                    mode = "file",
                                    size = file.filesize,
                                    modification = file.modification,
                                },
                                bidi_wrap_func = BD.filename,
                            }
                            if collate.item_func ~= nil then
                                collate.item_func(item, fc_self.ui)
                            end
                            item.bold = false
                            item.mandatory = fc_self:getMenuItemMandatory(item, collate)
                            table.insert(files, item)
                        else
                            table.insert(files, true)
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
                util.makePath(path)
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

function RemoteLibrary:downloadAndOpenFile(item)
    self:loadSettings()
    local cloudstorage_dir = self.settings:readSetting("cloudstorage_dir")
    if not cloudstorage_dir then
        UIManager:show(InfoMessage:new{
            text = _("Please configure the Cloudstorage directory first."),
            timeout = 3,
        })
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
            return
        end

        local progress_callback = function(progress)
            if not is_cancelled then
                progressbar_dialog:reportProgress(progress)
            end
        end

        logger.info("[RemoteLibrary] Starting download", "URL:", item.url, "local path:", item.path, "provider:", cloudstorage_dir.type)
        -- Ensure parent directory exists
        local local_dir = item.path:match("(.*)/")
        if local_dir then
            util.makePath(local_dir)
        end

        -- Download
        local code = provider.downloadFile(item.url, item.path, progress_callback)
        logger.info("[RemoteLibrary] Download finished", "code:", code, "file exists:", lfs.attributes(item.path) ~= nil)
        progressbar_dialog.dismiss_callback = nil
        progressbar_dialog:close()

        if is_cancelled then
            os.remove(item.path)
            return
        end

        if code == 200 then
            self.ui.file_chooser:refreshPath()
            filemanagerutil.openFile(self.ui, item.path)
        else
            UIManager:show(InfoMessage:new{
                text = string.format(_("Download failed: %s"), item.text:gsub("^%[Cloud%]%s*", "")),
                timeout = 3,
            })
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

