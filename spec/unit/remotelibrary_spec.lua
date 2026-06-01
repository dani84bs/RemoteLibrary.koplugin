describe("RemoteLibrary plugin", function()
    setup(function()
        require("commonrequire")
    end)

    it("can load metadata", function()
        local meta = dofile("plugins/RemoteLibrary.koplugin/_meta.lua")
        assert.is_table(meta)
        assert.equals("Remote Library", meta.fullname)
    end)

    it("can load main module", function()
        local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")
        assert.is_table(RemoteLibrary)
        assert.equals("remotelibrary", RemoteLibrary.name)
        assert.is_false(RemoteLibrary.is_doc_only)
    end)

    it("has addToMainMenu method and correct menu structure", function()
        local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")
        assert.is_function(RemoteLibrary.addToMainMenu)
        local menu_items = {}
        RemoteLibrary.addToMainMenu(nil, menu_items)
        assert.is_table(menu_items.remote_library)
        assert.equals("Remote Library", menu_items.remote_library.text)
        assert.equals("more_tools", menu_items.remote_library.sorting_hint)
        assert.is_table(menu_items.remote_library.sub_item_table)
        assert.equals("Settings", menu_items.remote_library.sub_item_table[1].text)
    end)

    it("can retrieve settings sub-menu items dynamically when configured", function()
        local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")
        local mock_instance = setmetatable({
            ui = {
                menu = {}
            },
            settings = {
                readSetting = function(self, key)
                    if key == "cloudstorage_dir" then
                        return { name = "MyWebDAV", url = "/books" }
                    end
                end
            },
            loadSettings = function() end
        }, { __index = RemoteLibrary })

        local sub_items = mock_instance:getSettingsSubMenuItems()
        assert.is_table(sub_items)
        assert.equals(1, #sub_items)
        assert.match("Cloudstorage directory: MyWebDAV: /books", sub_items[1].text)
    end)

    it("shows 'not set' when cloudstorage directory is not configured", function()
        local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")
        local mock_instance = setmetatable({
            ui = {
                menu = {}
            },
            settings = {
                readSetting = function(self, key)
                    return nil
                end
            },
            loadSettings = function() end
        }, { __index = RemoteLibrary })

        local sub_items = mock_instance:getSettingsSubMenuItems()
        assert.is_table(sub_items)
        assert.equals(1, #sub_items)
        assert.match("Cloudstorage directory: not set", sub_items[1].text)
    end)
end)
