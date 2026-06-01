--[[--
RemoteLibrary plugin allows browsing and reading files from a remote library server.

@module koplugin.RemoteLibrary
--]]--

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local RemoteLibrary = WidgetContainer:extend{
    name = "remotelibrary",
    is_doc_only = false,
}

function RemoteLibrary:init()
    -- Plugin registration and initialization stub
end

return RemoteLibrary
