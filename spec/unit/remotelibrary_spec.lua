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
        assert.equals("Reload", menu_items.remote_library.sub_item_table[2].text)
    end)

    it("triggers configuration warning and opens chooser when cloudstorage directory is not set", function()
        local UIManager = require("ui/uimanager")
        local original_show = UIManager.show
        local warning_shown = false
        UIManager.show = function(self, widget)
            if widget.text and widget.text:match("Please configure the Cloudstorage directory first.") then
                warning_shown = true
            end
        end

        local chooser_opened = false
        local mock_instance
        mock_instance = {
            ui = {
                cloudstorage = {
                    onShowCloudStorageList = function(self, callback)
                        chooser_opened = true
                    end
                }
            },
            settings = {
                readSetting = function(self, key)
                    return nil
                end
            },
            loadSettings = function() end
        }

        package.loaded["plugins/RemoteLibrary.koplugin/main.lua"] = nil
        local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")
        setmetatable(mock_instance, { __index = RemoteLibrary })

        mock_instance:reloadRemoteLibrary()

        UIManager.show = original_show
        assert.is_true(warning_shown)
        assert.is_true(chooser_opened)
    end)

    it("runs recursive scan and saves map on successful reload", function()
        local UIManager = require("ui/uimanager")
        local original_show = UIManager.show
        local original_nextTick = UIManager.nextTick

        local shown_infomsg = nil
        UIManager.show = function(self, widget)
            if widget.text then
                shown_infomsg = widget.text
            end
        end

        UIManager.nextTick = function(self, callback)
            callback()
        end

        package.loaded["ui/widget/progressbardialog"] = {
            new = function(self, args)
                return {
                    [1] = { { { setText = function() end } } },
                    redrawProgressbar = function() end,
                    show = function() end,
                    close = function() end,
                }
            end
        }

        local written_content = nil
        local original_io_open = io.open
        io.open = function(path, mode)
            if path:match("remotelibrary_map.lua") and mode == "w" then
                return {
                    write = function(self, content)
                        written_content = content
                    end,
                    close = function() end
                }
            end
            return original_io_open(path, mode)
        end

        package.loaded["plugins/RemoteLibrary.koplugin/main.lua"] = nil
        local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")

        local list_folder_calls = 0
        local mock_instance = setmetatable({
            ui = {
                cloudstorage = {
                    getProviders = function() end,
                    loadSettings = function() end,
                    providers = {
                        webdav = {
                            run = function(callback)
                                callback()
                            end,
                            listFolder = function(url, include_folders)
                                list_folder_calls = list_folder_calls + 1
                                if url == "/books" then
                                    return {
                                        { text = "book1.epub", is_file = true, url = "/books/book1.epub", filesize = 1024 },
                                        { text = "fiction", is_folder = true, url = "/books/fiction" }
                                    }
                                elseif url == "/books/fiction" then
                                    return {
                                        { text = "book2.epub", is_file = true, url = "/books/fiction/book2.epub", filesize = 2048 }
                                    }
                                end
                                return {}
                            end
                        }
                    }
                }
            },
            settings = {
                readSetting = function(self, key)
                    if key == "cloudstorage_dir" then
                        return { type = "webdav", url = "/books" }
                    end
                end
            },
            loadSettings = function() end
        }, { __index = RemoteLibrary })

        mock_instance:reloadRemoteLibrary()

        UIManager.show = original_show
        UIManager.nextTick = original_nextTick
        io.open = original_io_open

        assert.equals(2, list_folder_calls)
        assert.match("Reload complete: 1 folders and 2 files mapped.", shown_infomsg)
        assert.is_string(written_content)
        assert.match("book1.epub", written_content)
        assert.match("book2.epub", written_content)
        assert.match("fiction", written_content)
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
