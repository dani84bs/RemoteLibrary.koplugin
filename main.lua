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
            }
        }
    }
end

return RemoteLibrary

