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
local _ = require("gettext")

local RemoteLibrary = WidgetContainer:extend{
    name = "remotelibrary",
    is_doc_only = false,
    settings_file = DataStorage:getSettingsDir() .. "/remotelibrary.lua",
    settings = nil,
    updated = nil,
}

function RemoteLibrary:init()
    self.ui.menu:registerToMainMenu(self)
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

