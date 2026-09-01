describe("RemoteLibrary plugin", function()
    local orig_path

    setup(function()
        orig_path = package.path
        package.path = "plugins/RemoteLibrary.koplugin/?.lua;" .. package.path
        require("commonrequire")
    end)

    teardown(function()
        package.path = orig_path
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

    it("does not attempt the WebDAV deep-scan fast path when address is not set", function()
        local UIManager = require("ui/uimanager")
        local original_show = UIManager.show
        local original_nextTick = UIManager.nextTick

        UIManager.show = function(self, widget) end
        UIManager.nextTick = function(self, callback) callback() end

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

        local original_http = package.loaded["socket.http"]
        local http_request_called = false
        package.loaded["socket.http"] = {
            request = function(req)
                http_request_called = true
                return 1, 500, {}, "should not be called"
            end
        }

        local original_io_open = io.open
        io.open = function(path, mode)
            if path:match("remotelibrary_map.lua") and mode == "w" then
                return { write = function() end, close = function() end }
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
                            run = function(callback) callback() end,
                            listFolder = function(url, include_folders)
                                list_folder_calls = list_folder_calls + 1
                                return {}
                            end
                        }
                    }
                }
            },
            settings = {
                readSetting = function(self, key)
                    if key == "cloudstorage_dir" then
                        -- no `address` field, mirroring the existing mock config
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
        package.loaded["socket.http"] = original_http

        assert.is_false(http_request_called)
        assert.equals(1, list_folder_calls)
    end)

    it("uses a single Depth:infinity PROPFIND request when address is configured", function()
        local UIManager = require("ui/uimanager")
        local original_show = UIManager.show
        local original_nextTick = UIManager.nextTick

        local shown_infomsg = nil
        UIManager.show = function(self, widget)
            if widget.text then
                shown_infomsg = widget.text
            end
        end
        UIManager.nextTick = function(self, callback) callback() end

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
                    write = function(self, content) written_content = content end,
                    close = function() end,
                }
            end
            return original_io_open(path, mode)
        end

        local original_http = package.loaded["socket.http"]
        local http_request_calls = 0
        package.loaded["socket.http"] = {
            request = function(req)
                http_request_calls = http_request_calls + 1
                local body = table.concat({
                    [[<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">]],
                    [[<d:response><d:href>/dav/books/</d:href><d:propstat><d:prop>]],
                    [[<d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>]],
                    [[<d:response><d:href>/dav/books/book1.epub</d:href><d:propstat><d:prop>]],
                    [[<d:resourcetype/><d:getcontentlength>1024</d:getcontentlength></d:prop></d:propstat></d:response>]],
                    [[<d:response><d:href>/dav/books/fiction/</d:href><d:propstat><d:prop>]],
                    [[<d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>]],
                    [[<d:response><d:href>/dav/books/fiction/book2.epub</d:href><d:propstat><d:prop>]],
                    [[<d:resourcetype/><d:getcontentlength>2048</d:getcontentlength></d:prop></d:propstat></d:response>]],
                    [[</d:multistatus>]],
                })
                req.sink(body)
                req.sink(nil)
                return 1, 207, { ["content-type"] = "application/xml" }, "HTTP/1.1 207 Multi-Status"
            end
        }

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
                            run = function(callback) callback() end,
                            listFolder = function(url, include_folders)
                                list_folder_calls = list_folder_calls + 1
                                return {}
                            end
                        }
                    }
                }
            },
            settings = {
                readSetting = function(self, key)
                    if key == "cloudstorage_dir" then
                        return { type = "webdav", url = "/books", address = "https://example.com/dav" }
                    end
                end
            },
            loadSettings = function() end
        }, { __index = RemoteLibrary })

        mock_instance:reloadRemoteLibrary()

        UIManager.show = original_show
        UIManager.nextTick = original_nextTick
        io.open = original_io_open
        package.loaded["socket.http"] = original_http

        assert.equals(1, http_request_calls)
        assert.equals(0, list_folder_calls)
        assert.match("Reload complete: 1 folders and 2 files mapped.", shown_infomsg)
        assert.is_string(written_content)
        assert.match("book1.epub", written_content)
        assert.match("book2.epub", written_content)
        assert.match("fiction", written_content)
    end)

    it("falls back to the per-folder crawl when the PROPFIND deep-scan fails", function()
        local UIManager = require("ui/uimanager")
        local original_show = UIManager.show
        local original_nextTick = UIManager.nextTick

        local shown_infomsg = nil
        UIManager.show = function(self, widget)
            if widget.text then
                shown_infomsg = widget.text
            end
        end
        UIManager.nextTick = function(self, callback) callback() end

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

        local original_io_open = io.open
        io.open = function(path, mode)
            if path:match("remotelibrary_map.lua") and mode == "w" then
                return { write = function() end, close = function() end }
            end
            return original_io_open(path, mode)
        end

        local original_http = package.loaded["socket.http"]
        package.loaded["socket.http"] = {
            request = function(req)
                -- server rejects Depth: infinity
                return 1, 403, {}, "HTTP/1.1 403 Forbidden"
            end
        }

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
                            run = function(callback) callback() end,
                            listFolder = function(url, include_folders)
                                list_folder_calls = list_folder_calls + 1
                                return {}
                            end
                        }
                    }
                }
            },
            settings = {
                readSetting = function(self, key)
                    if key == "cloudstorage_dir" then
                        return { type = "webdav", url = "/books", address = "https://example.com/dav" }
                    end
                end
            },
            loadSettings = function() end
        }, { __index = RemoteLibrary })

        mock_instance:reloadRemoteLibrary()

        UIManager.show = original_show
        UIManager.nextTick = original_nextTick
        io.open = original_io_open
        package.loaded["socket.http"] = original_http

        assert.equals(1, list_folder_calls)
        assert.match("Reload complete: 0 folders and 0 files mapped.", shown_infomsg)
    end)

    it("falls back to the per-folder crawl when PROPFIND returns 401", function()
        package.path = package.path .. ";plugins/RemoteLibrary.koplugin/spec/unit/?.lua"
        local spec_support = require("remotelibrary_spec_support")
        local UIManager = require("ui/uimanager")

        local shown_infomsg = nil
        local restore_show = spec_support.patch(UIManager, "show", function(self, widget)
            if widget.text then shown_infomsg = widget.text end
        end)
        local restore_nextTick = spec_support.patch(UIManager, "nextTick", function(self, callback) callback() end)

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

        local restore_io_open = spec_support.patch(io, "open", function(path, mode)
            if path:match("remotelibrary_map.lua") and mode == "w" then
                return { write = function() end, close = function() end }
            end
            return nil
        end)

        local restore_http = spec_support.patch(package.loaded, "socket.http", {
            request = function(req)
                return 1, 401, {}, "HTTP/1.1 401 Unauthorized"
            end
        })

        package.loaded["plugins/RemoteLibrary.koplugin/main.lua"] = nil
        local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")

        local list_folder_calls = 0
        local mock_instance = spec_support.mockInstance(RemoteLibrary, {
            ui = {
                cloudstorage = {
                    getProviders = function() end,
                    loadSettings = function() end,
                    providers = {
                        webdav = {
                            run = function(callback) callback() end,
                            listFolder = function(url, include_folders)
                                list_folder_calls = list_folder_calls + 1
                                return {}
                            end
                        }
                    }
                }
            },
            settings = {
                readSetting = function(self, key)
                    if key == "cloudstorage_dir" then
                        return { type = "webdav", url = "/books", address = "https://example.com/dav" }
                    end
                end
            },
            loadSettings = function() end
        })

        mock_instance:reloadRemoteLibrary()

        restore_show()
        restore_nextTick()
        restore_io_open()
        restore_http()

        assert.equals(1, list_folder_calls)
        assert.match("Reload complete: 0 folders and 0 files mapped.", shown_infomsg)
    end)

    it("does not add garbage entries when PROPFIND returns unparseable XML", function()
        package.path = package.path .. ";plugins/RemoteLibrary.koplugin/spec/unit/?.lua"
        local spec_support = require("remotelibrary_spec_support")
        local UIManager = require("ui/uimanager")

        local shown_infomsg = nil
        local restore_show = spec_support.patch(UIManager, "show", function(self, widget)
            if widget.text then shown_infomsg = widget.text end
        end)
        local restore_nextTick = spec_support.patch(UIManager, "nextTick", function(self, callback) callback() end)

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
        local restore_io_open = spec_support.patch(io, "open", function(path, mode)
            if path:match("remotelibrary_map.lua") and mode == "w" then
                return {
                    write = function(self, content) written_content = content end,
                    close = function() end,
                }
            end
            return nil
        end)

        local restore_http = spec_support.patch(package.loaded, "socket.http", {
            request = function(req)
                req.sink("this is not xml at all, just garbage <<< >>>")
                req.sink(nil)
                return 1, 207, { ["content-type"] = "application/xml" }, "HTTP/1.1 207 Multi-Status"
            end
        })

        package.loaded["plugins/RemoteLibrary.koplugin/main.lua"] = nil
        local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")

        local list_folder_calls = 0
        local mock_instance = spec_support.mockInstance(RemoteLibrary, {
            ui = {
                cloudstorage = {
                    getProviders = function() end,
                    loadSettings = function() end,
                    providers = {
                        webdav = {
                            run = function(callback) callback() end,
                            listFolder = function(url, include_folders)
                                list_folder_calls = list_folder_calls + 1
                                return {}
                            end
                        }
                    }
                }
            },
            settings = {
                readSetting = function(self, key)
                    if key == "cloudstorage_dir" then
                        return { type = "webdav", url = "/books", address = "https://example.com/dav" }
                    end
                end
            },
            loadSettings = function() end
        })

        mock_instance:reloadRemoteLibrary()

        restore_show()
        restore_nextTick()
        restore_io_open()
        restore_http()

        -- Malformed XML that doesn't match the expected response pattern yields no
        -- entries, so the deep-scan "succeeds" with an empty tree rather than crashing.
        assert.equals(0, list_folder_calls)
        assert.match("Reload complete: 0 folders and 0 files mapped.", shown_infomsg)
        assert.is_string(written_content)
        assert.not_match("book1.epub", written_content)
    end)

    it("falls back to the per-folder crawl when the PROPFIND request itself fails", function()
        package.path = package.path .. ";plugins/RemoteLibrary.koplugin/spec/unit/?.lua"
        local spec_support = require("remotelibrary_spec_support")
        local UIManager = require("ui/uimanager")

        local shown_infomsg = nil
        local restore_show = spec_support.patch(UIManager, "show", function(self, widget)
            if widget.text then shown_infomsg = widget.text end
        end)
        local restore_nextTick = spec_support.patch(UIManager, "nextTick", function(self, callback) callback() end)

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

        local restore_io_open = spec_support.patch(io, "open", function(path, mode)
            if path:match("remotelibrary_map.lua") and mode == "w" then
                return { write = function() end, close = function() end }
            end
            return nil
        end)

        local restore_http = spec_support.patch(package.loaded, "socket.http", {
            request = function(req)
                error("connection timed out")
            end
        })

        package.loaded["plugins/RemoteLibrary.koplugin/main.lua"] = nil
        local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")

        local list_folder_calls = 0
        local mock_instance = spec_support.mockInstance(RemoteLibrary, {
            ui = {
                cloudstorage = {
                    getProviders = function() end,
                    loadSettings = function() end,
                    providers = {
                        webdav = {
                            run = function(callback) callback() end,
                            listFolder = function(url, include_folders)
                                list_folder_calls = list_folder_calls + 1
                                return {}
                            end
                        }
                    }
                }
            },
            settings = {
                readSetting = function(self, key)
                    if key == "cloudstorage_dir" then
                        return { type = "webdav", url = "/books", address = "https://example.com/dav" }
                    end
                end
            },
            loadSettings = function() end
        })

        mock_instance:reloadRemoteLibrary()

        restore_show()
        restore_nextTick()
        restore_io_open()
        restore_http()

        assert.equals(1, list_folder_calls)
        assert.match("Reload complete: 0 folders and 0 files mapped.", shown_infomsg)
    end)

    it("continues the per-folder crawl when listFolder fails for one folder", function()
        package.path = package.path .. ";plugins/RemoteLibrary.koplugin/spec/unit/?.lua"
        local spec_support = require("remotelibrary_spec_support")
        local UIManager = require("ui/uimanager")

        local shown_infomsg = nil
        local restore_show = spec_support.patch(UIManager, "show", function(self, widget)
            if widget.text then shown_infomsg = widget.text end
        end)
        local restore_nextTick = spec_support.patch(UIManager, "nextTick", function(self, callback) callback() end)

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
        local restore_io_open = spec_support.patch(io, "open", function(path, mode)
            if path:match("remotelibrary_map.lua") and mode == "w" then
                return {
                    write = function(self, content) written_content = content end,
                    close = function() end,
                }
            end
            return nil
        end)

        package.loaded["plugins/RemoteLibrary.koplugin/main.lua"] = nil
        local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")

        local list_folder_calls = 0
        local mock_instance = spec_support.mockInstance(RemoteLibrary, {
            ui = {
                cloudstorage = {
                    getProviders = function() end,
                    loadSettings = function() end,
                    providers = {
                        webdav = {
                            run = function(callback) callback() end,
                            listFolder = function(url, include_folders)
                                list_folder_calls = list_folder_calls + 1
                                if url == "/books" then
                                    return {
                                        { text = "broken", is_folder = true, url = "/books/broken" },
                                        { text = "fiction", is_folder = true, url = "/books/fiction" }
                                    }
                                elseif url == "/books/broken" then
                                    -- fails outright (e.g. timeout), returns nil
                                    return nil
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
        })

        mock_instance:reloadRemoteLibrary()

        restore_show()
        restore_nextTick()
        restore_io_open()

        assert.equals(3, list_folder_calls)
        assert.match("Reload complete: 2 folders and 1 files mapped.", shown_infomsg)
        assert.is_string(written_content)
        assert.match("book2.epub", written_content)
    end)

    it("shows 'Cloud storage provider not found.' for a missing/unsupported provider type", function()
        package.path = package.path .. ";plugins/RemoteLibrary.koplugin/spec/unit/?.lua"
        local spec_support = require("remotelibrary_spec_support")
        local UIManager = require("ui/uimanager")

        local shown_infomsg = nil
        local restore_show = spec_support.patch(UIManager, "show", function(self, widget)
            if widget.text then shown_infomsg = widget.text end
        end)

        package.loaded["plugins/RemoteLibrary.koplugin/main.lua"] = nil
        local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")

        local mock_instance = spec_support.mockInstance(RemoteLibrary, {
            ui = {
                cloudstorage = {
                    getProviders = function() end,
                    loadSettings = function() end,
                    providers = {}
                }
            },
            settings = {
                readSetting = function(self, key)
                    if key == "cloudstorage_dir" then
                        return { type = "unsupported_provider", url = "/books" }
                    end
                end
            },
            loadSettings = function() end
        })

        mock_instance:reloadRemoteLibrary()

        restore_show()

        assert.match("Cloud storage provider not found.", shown_infomsg)
    end)

    it("saves partial progress and shows a message when reload is cancelled mid-scan", function()
        local UIManager = require("ui/uimanager")
        local original_show = UIManager.show
        local original_nextTick = UIManager.nextTick

        local shown_infomsg = nil
        UIManager.show = function(self, widget)
            if widget.text then
                shown_infomsg = widget.text
            end
        end
        UIManager.nextTick = function(self, callback) callback() end

        local captured_dismiss_callback = nil
        package.loaded["ui/widget/progressbardialog"] = {
            new = function(self, args)
                captured_dismiss_callback = args.dismiss_callback
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
                    write = function(self, content) written_content = content end,
                    close = function() end,
                }
            end
            return original_io_open(path, mode)
        end

        package.loaded["plugins/RemoteLibrary.koplugin/main.lua"] = nil
        local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")

        local mock_instance = setmetatable({
            ui = {
                cloudstorage = {
                    getProviders = function() end,
                    loadSettings = function() end,
                    providers = {
                        webdav = {
                            run = function(callback) callback() end,
                            listFolder = function(url, include_folders)
                                if url == "/books" then
                                    -- simulate the user cancelling right after the first folder is fetched
                                    captured_dismiss_callback()
                                    return {
                                        { text = "book1.epub", is_file = true, url = "/books/book1.epub", filesize = 1024 },
                                        { text = "fiction", is_folder = true, url = "/books/fiction" }
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
                        -- no `address` field, so this exercises the per-folder crawl
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

        assert.match("Reload cancelled: 1 folders and 1 files mapped so far.", shown_infomsg)
        assert.is_string(written_content)
        assert.match("book1.epub", written_content)
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

    it("can retrieve settings sub-menu items dynamically when configured (via spec_support)", function()
        package.path = package.path .. ";plugins/RemoteLibrary.koplugin/spec/unit/?.lua"
        local spec_support = require("remotelibrary_spec_support")
        local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")
        local mock_instance = spec_support.mockInstance(RemoteLibrary, {
            ui = { menu = {} },
            settings = {
                readSetting = function(self, key)
                    if key == "cloudstorage_dir" then
                        return { name = "MyWebDAV", url = "/books" }
                    end
                end
            },
            loadSettings = function() end
        })

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

    it("flushes settings only when the updated flag is set", function()
        package.path = package.path .. ";plugins/RemoteLibrary.koplugin/spec/unit/?.lua"
        local spec_support = require("remotelibrary_spec_support")
        local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")

        local flush_called = false
        local mock_instance = spec_support.mockInstance(RemoteLibrary, {
            updated = true,
            settings = { flush = function() flush_called = true end }
        })

        mock_instance:onFlushSettings()
        assert.is_true(flush_called)
        assert.is_nil(mock_instance.updated)

        flush_called = false
        mock_instance:onFlushSettings()
        assert.is_false(flush_called)
    end)

    it("invokes downloadRemoteFile and opens the file on success", function()
        package.path = package.path .. ";plugins/RemoteLibrary.koplugin/spec/unit/?.lua"
        local spec_support = require("remotelibrary_spec_support")
        local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")

        local filemanagerutil = require("apps/filemanager/filemanagerutil")
        local opened_ui, opened_path
        local restore_openFile = spec_support.patch(filemanagerutil, "openFile", function(ui, path)
            opened_ui, opened_path = ui, path
        end)

        local download_called_with
        local mock_instance = spec_support.mockInstance(RemoteLibrary, {
            ui = { fake_ui = true },
            downloadRemoteFile = function(self, item, callback)
                download_called_with = item
                callback(true)
            end
        })

        local item = { path = "/books/remote_book.epub", text = "[Cloud] remote_book.epub" }
        mock_instance:downloadAndOpenFile(item)

        restore_openFile()

        assert.equals(item, download_called_with)
        assert.equals(mock_instance.ui, opened_ui)
        assert.equals("/books/remote_book.epub", opened_path)
    end)

    it("does not open the file when downloadRemoteFile reports failure", function()
        package.path = package.path .. ";plugins/RemoteLibrary.koplugin/spec/unit/?.lua"
        local spec_support = require("remotelibrary_spec_support")
        local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")

        local filemanagerutil = require("apps/filemanager/filemanagerutil")
        local open_called = false
        local restore_openFile = spec_support.patch(filemanagerutil, "openFile", function()
            open_called = true
        end)

        local mock_instance = spec_support.mockInstance(RemoteLibrary, {
            ui = { fake_ui = true },
            downloadRemoteFile = function(self, item, callback)
                callback(false)
            end
        })

        mock_instance:downloadAndOpenFile({ path = "/books/remote_book.epub" })

        restore_openFile()

        assert.is_false(open_called)
    end)

    it("shows 'Cloud storage provider not found.' when downloadRemoteFile has a missing/unsupported provider type", function()
        package.path = package.path .. ";plugins/RemoteLibrary.koplugin/spec/unit/?.lua"
        local spec_support = require("remotelibrary_spec_support")
        local UIManager = require("ui/uimanager")

        local shown_infomsg = nil
        local restore_show = spec_support.patch(UIManager, "show", function(self, widget)
            if widget.text then shown_infomsg = widget.text end
        end)

        local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")

        local mock_instance = spec_support.mockInstance(RemoteLibrary, {
            ui = {
                cloudstorage = {
                    getProviders = function() end,
                    loadSettings = function() end,
                    providers = {}
                }
            },
            settings = {
                readSetting = function(self, key)
                    if key == "cloudstorage_dir" then
                        return { type = "unsupported_provider", url = "/books" }
                    end
                end
            },
            loadSettings = function() end
        })

        local callback_result
        mock_instance:downloadRemoteFile({ text = "book.epub", path = "/books/book.epub" }, function(success)
            callback_result = success
        end)

        restore_show()

        assert.match("Cloud storage provider not found.", shown_infomsg)
        assert.is_false(callback_result)
    end)

    it("shows 'Download failed' and removes the partial file when provider.downloadFile returns a non-200 code", function()
        package.path = package.path .. ";plugins/RemoteLibrary.koplugin/spec/unit/?.lua"
        local spec_support = require("remotelibrary_spec_support")
        local UIManager = require("ui/uimanager")
        local DataStorage = require("datastorage")

        local shown_infomsg = nil
        local restore_show = spec_support.patch(UIManager, "show", function(self, widget)
            if widget.text then shown_infomsg = widget.text end
        end)

        local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")

        local lfs = require("libs/libkoreader-lfs")
        local restore_original_attributes = spec_support.patch(lfs, "original_attributes", lfs.attributes)

        local target_path = DataStorage:getSettingsDir() .. "/remotelibrary_test_partial.epub"
        os.remove(target_path)

        local mock_instance = spec_support.mockInstance(RemoteLibrary, {
            ui = {
                cloudstorage = {
                    getProviders = function() end,
                    loadSettings = function() end,
                    providers = {
                        webdav = {
                            run = function(callback) callback() end,
                            downloadFile = function(url, path)
                                -- simulate a partial write left behind by a failed transfer
                                local f = io.open(path, "w")
                                f:write("partial")
                                f:close()
                                return 404
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
        })

        local callback_result
        mock_instance:downloadRemoteFile({ text = "book.epub", path = target_path, url = "/book.epub" }, function(success)
            callback_result = success
        end)

        restore_show()
        restore_original_attributes()

        local leftover_exists = lfs.attributes(target_path, "mode") == "file"
        os.remove(target_path)

        assert.match("Download failed: book.epub", shown_infomsg)
        assert.is_false(callback_result)
        assert.is_false(leftover_exists)
    end)

    it("handles an io.open failure gracefully when saveMap persists the remote library map", function()
        package.path = package.path .. ";plugins/RemoteLibrary.koplugin/spec/unit/?.lua"
        local spec_support = require("remotelibrary_spec_support")
        local UIManager = require("ui/uimanager")
        local DataStorage = require("datastorage")

        local shown_infomsg = nil
        local restore_show = spec_support.patch(UIManager, "show", function(self, widget)
            if widget.text then shown_infomsg = widget.text end
        end)
        local restore_nextTick = spec_support.patch(UIManager, "nextTick", function(self, callback) callback() end)

        local restore_progressbar = spec_support.patch(package.loaded, "ui/widget/progressbardialog", {
            new = function(self, args)
                return {
                    [1] = { { { setText = function() end } } },
                    redrawProgressbar = function() end,
                    show = function() end,
                    close = function() end,
                }
            end
        })

        local map_file_path = DataStorage:getSettingsDir() .. "/remotelibrary_map.lua"
        local original_io_open = io.open
        local restore_io_open = spec_support.patch(io, "open", function(path, mode)
            if path == map_file_path and mode == "w" then
                return nil
            end
            return original_io_open(path, mode)
        end)

        package.loaded["plugins/RemoteLibrary.koplugin/main.lua"] = nil
        local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")

        local mock_instance = spec_support.mockInstance(RemoteLibrary, {
            ui = {
                cloudstorage = {
                    getProviders = function() end,
                    loadSettings = function() end,
                    providers = {
                        webdav = {
                            run = function(callback) callback() end,
                            listFolder = function(url, include_folders)
                                if url == "/books" then
                                    return {
                                        { text = "book1.epub", is_file = true, url = "/books/book1.epub", filesize = 1024 }
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
        })

        assert.has_no.errors(function()
            mock_instance:reloadRemoteLibrary()
        end)

        restore_show()
        restore_nextTick()
        restore_progressbar()
        restore_io_open()

        assert.match("Reload complete: 0 folders and 1 files mapped.", shown_infomsg)
    end)

    describe("Map Overlay", function()
        local original_attributes
        local original_realpath
        local original_path

        before_each(function()
            original_path = package.path
            package.path = package.path .. ";plugins/coverbrowser.koplugin/?.lua"
            local DataStorage = require("datastorage")
            local lfs = require("libs/libkoreader-lfs")
            original_attributes = lfs.attributes

            local ffiUtil = require("ffi/util")
            original_realpath = ffiUtil.realpath

            _G.G_reader_settings = {
                readSetting = function(self, key, default)
                    if key == "home_dir" then
                        return "/books"
                    end
                    return default
                end,
                nilOrTrue = function(self, key)
                    return true
                end,
                isTrue = function(self, key)
                    return false
                end,
                isFalse = function(self, key)
                    return false
                end
            }
            _G.Device = {
                home_dir = "/books"
            }

            local map_file_path = DataStorage:getSettingsDir() .. "/remotelibrary_map.lua"
            local f = io.open(map_file_path, "w")
            if f then
                f:write([[
return {
    files = {
        { name = "remote_book.epub", url = "/remote_book.epub", filesize = 1024 }
    },
    folders = {
        ["remote_folder/"] = {
            files = {
                { name = "nested_book.epub", url = "/remote_folder/nested_book.epub", filesize = 512 }
            },
            folders = {
                ["nested_folder/"] = {
                    files = {},
                    folders = {}
                }
            }
        }
    }
}
]])
                f:close()
            end
        end)

        after_each(function()
            local DataStorage = require("datastorage")
            local lfs = require("libs/libkoreader-lfs")
            lfs.attributes = original_attributes
            lfs._remotelibrary_patched = nil
            lfs.original_attributes = nil
            lfs.original_dir = nil

            local ffiUtil = require("ffi/util")
            ffiUtil.realpath = original_realpath
            ffiUtil._remotelibrary_patched = nil
            ffiUtil.original_realpath = nil

            package.path = original_path
            _G.G_reader_settings = nil
            _G.Device = nil

            local map_file_path = DataStorage:getSettingsDir() .. "/remotelibrary_map.lua"
            os.remove(map_file_path)
        end)

        it("hooks setupLayout and applies overlay for home directory", function()
            local lfs = require("libs/libkoreader-lfs")

            lfs.attributes = function(path, key)
                if path:match("remote_book.epub") or path:match("remote_folder") then
                    return nil
                end
                if path:match("/books$") or path:match("/books/remote_folder$") or path:match("collection") then
                    if key then
                        if key == "mode" then return "directory" end
                        if key == "modification" then return 1 end
                        return nil
                    end
                    return { mode = "directory", modification = 1 }
                end
                return original_attributes(path, key)
            end

            package.loaded["plugins/RemoteLibrary.koplugin/main.lua"] = nil
            local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")

            local mock_ui = {
                menu = { registerToMainMenu = function() end }
            }
            local plugin_instance = setmetatable({
                ui = mock_ui,
                settings = {
                    readSetting = function() return nil end
                },
                loadSettings = function() end
            }, { __index = RemoteLibrary })

            plugin_instance:init()

            local FileManager = require("apps/filemanager/filemanager")
            local mock_fc = {
                path = "/books",
                getList = function(self, path, collate)
                    return {}, {}
                end,
                getMenuItemMandatory = function() return "1 KB" end,
                changeToPath = function() end,
                onFileSelect = function() end,
                showFileDialog = function() end,
                ui = {},
            }
            local mock_fm = {
                remotelibrary = plugin_instance,
                file_chooser = mock_fc,
                folder_shortcuts = {
                    hasFolderShortcut = function() return false end
                },
                registerKeyEvents = function() end,
            }

            FileManager.setupLayout(mock_fm)

            local dirs, files = mock_fm.file_chooser:getList("/books", { item_func = function() end })

            assert.equals(1, #dirs)
            assert.equals("[Cloud] remote_folder/", dirs[1].text)
            assert.is_true(dirs[1].is_proxy)

            assert.equals(1, #files)
            assert.equals("[Cloud] remote_book.epub", files[1].text)
            assert.is_true(files[1].is_proxy)

            -- Test nested subdirectory mapping
            local nested_dirs, nested_files = mock_fm.file_chooser:getList("/books/remote_folder", { item_func = function() end })
            assert.equals(1, #nested_dirs)
            assert.equals("[Cloud] nested_folder/", nested_dirs[1].text)
            assert.is_true(nested_dirs[1].is_proxy)

            assert.equals(1, #nested_files)
            assert.equals("[Cloud] nested_book.epub", nested_files[1].text)
            assert.is_true(nested_files[1].is_proxy)

            local BookInfoManager = require("bookinfomanager")
            local info = BookInfoManager:getBookInfo("/books/remote_book.epub")
            assert.is_table(info)
            assert.equals("Y", info.ignore_cover)
            assert.is_false(info.ignore_meta)
            assert.equals("remote_book", info.title)
            assert.equals("[Cloud]", info.authors)
            assert.is_true(info._no_provider)
        end)

        it("automatically hooks FileChooser on instantiation via global init patch", function()
            package.loaded["plugins/RemoteLibrary.koplugin/main.lua"] = nil
            local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")

            local mock_ui = {
                menu = { registerToMainMenu = function() end }
            }
            local plugin_instance = setmetatable({
                ui = mock_ui,
                settings = {
                    readSetting = function() return nil end
                },
                loadSettings = function() end
            }, { __index = RemoteLibrary })

            plugin_instance:init()

            local BookList = require("ui/widget/booklist")
            local original_BookList_init = BookList.init
            BookList.init = function() end

            local FileChooser = require("ui/widget/filechooser")
            local mock_fc = setmetatable({
                path = "/books",
                ui = {
                    RemoteLibrary = plugin_instance,
                },
                refreshPath = function() end,
            }, { __index = FileChooser })

            -- Call the patched init
            FileChooser.init(mock_fc)

            BookList.init = original_BookList_init

            assert.is_true(mock_fc._remotelibrary_patched)
        end)

        it("does not overlay remote items when browsing outside home_dir", function()
            package.loaded["plugins/RemoteLibrary.koplugin/main.lua"] = nil
            local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")

            local mock_fc = {
                path = "/other_path",
                getList = function() return {}, {} end,
                getMenuItemMandatory = function() return "" end,
                changeToPath = function() end,
                onFileSelect = function() end,
                showFileDialog = function() end,
                ui = {},
            }
            local plugin_instance = setmetatable({
                ui = { menu = { registerToMainMenu = function() end } },
                settings = { readSetting = function() return nil end },
                loadSettings = function() end
            }, { __index = RemoteLibrary })

            plugin_instance:hookFileChooser(mock_fc)

            local dirs, files = mock_fc:getList("/other_path", { item_func = function() end })
            assert.equals(0, #dirs)
            assert.equals(0, #files)
        end)

        it("intercepts onFileSelect and shows ConfirmBox for proxy file", function()
            local UIManager = require("ui/uimanager")
            local original_show = UIManager.show
            local dialog_shown = nil
            UIManager.show = function(self, widget)
                dialog_shown = widget
            end

            package.loaded["plugins/RemoteLibrary.koplugin/main.lua"] = nil
            local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")

            local mock_fc = {
                path = "/books",
                getList = function() return {}, {} end,
                getMenuItemMandatory = function() return "" end,
                changeToPath = function() end,
                onFileSelect = function() end,
                showFileDialog = function() end,
                ui = {},
            }
            local download_called = false
            local plugin_instance = setmetatable({
                ui = { menu = { registerToMainMenu = function() end } },
                settings = { readSetting = function() return nil end },
                loadSettings = function() end,
                downloadAndOpenFile = function() download_called = true end
            }, { __index = RemoteLibrary })

            plugin_instance:hookFileChooser(mock_fc)

            local proxy_item = { is_proxy = true, is_file = true, text = "[Cloud] book.epub" }
            mock_fc:onFileSelect(proxy_item)

            UIManager.show = original_show

            assert.is_not_nil(dialog_shown)
            assert.equals("Would you like to download book.epub?", dialog_shown.text)
            assert.equals("Download", dialog_shown.ok_text)
            assert.equals("Cancel", dialog_shown.cancel_text)

            dialog_shown.ok_callback()
            assert.is_true(download_called)
        end)

        it("does not intercept onFileSelect for proxy folders", function()
            package.loaded["plugins/RemoteLibrary.koplugin/main.lua"] = nil
            local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")

            local original_onFileSelect_called = false
            local mock_fc = {
                path = "/books",
                getList = function() return {}, {} end,
                getMenuItemMandatory = function() return "" end,
                changeToPath = function() end,
                onFileSelect = function() original_onFileSelect_called = true end,
                showFileDialog = function() end,
                ui = {},
            }
            local download_called = false
            local plugin_instance = setmetatable({
                ui = { menu = { registerToMainMenu = function() end } },
                settings = { readSetting = function() return nil end },
                loadSettings = function() end,
                downloadAndOpenFile = function() download_called = true end
            }, { __index = RemoteLibrary })

            plugin_instance:hookFileChooser(mock_fc)

            local proxy_folder = { is_proxy = true, is_folder = true, text = "[Cloud] folder/" }
            mock_fc:onFileSelect(proxy_folder)

            assert.is_false(download_called)
            assert.is_true(original_onFileSelect_called)
        end)

        it("intercepts showFileDialog and returns true without showing dialog for proxy file", function()
            local UIManager = require("ui/uimanager")
            local original_show = UIManager.show
            local dialog_shown = nil

            UIManager.show = function(self, widget)
                dialog_shown = widget
            end

            package.loaded["plugins/RemoteLibrary.koplugin/main.lua"] = nil
            local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")

            local mock_fc = {
                path = "/books",
                getList = function() return {}, {} end,
                getMenuItemMandatory = function() return "" end,
                changeToPath = function() end,
                onFileSelect = function() end,
                showFileDialog = function() end,
                ui = {},
            }
            local plugin_instance = setmetatable({
                ui = { menu = { registerToMainMenu = function() end } },
                settings = { readSetting = function() return nil end },
                loadSettings = function() end
            }, { __index = RemoteLibrary })

            plugin_instance:hookFileChooser(mock_fc)

            local proxy_item = { is_proxy = true, is_file = true, text = "[☁️] book.epub" }
            local res = mock_fc:showFileDialog(proxy_item)

            UIManager.show = original_show

            assert.is_true(res)
            assert.is_nil(dialog_shown)
        end)

        it("blocks onFileSelect for proxy file in select mode", function()
            local spec_support = require("remotelibrary_spec_support")
            local UIManager = require("ui/uimanager")

            local dialog_shown = nil
            local restore_show = spec_support.patch(UIManager, "show", function(self, widget)
                dialog_shown = widget
            end)

            package.loaded["plugins/RemoteLibrary.koplugin/main.lua"] = nil
            local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")

            local mock_fc = {
                path = "/books",
                getList = function() return {}, {} end,
                getMenuItemMandatory = function() return "" end,
                changeToPath = function() end,
                onFileSelect = function() end,
                showFileDialog = function() end,
                ui = { selected_files = { ["/books/book.epub"] = true } },
            }
            local download_called = false
            local plugin_instance = spec_support.mockInstance(RemoteLibrary, {
                ui = { menu = { registerToMainMenu = function() end } },
                settings = { readSetting = function() return nil end },
                loadSettings = function() end,
                downloadAndOpenFile = function() download_called = true end
            })

            plugin_instance:hookFileChooser(mock_fc)

            local proxy_item = { is_proxy = true, is_file = true, text = "[Cloud] book.epub" }
            local res = mock_fc:onFileSelect(proxy_item)

            restore_show()

            assert.is_true(res)
            assert.is_false(download_called)
            assert.is_not_nil(dialog_shown)
            assert.equals(
                "Operations on remote proxy files are not supported in select mode.",
                dialog_shown.text
            )
        end)

        it("does not intercept showFileDialog for a non-proxy file", function()
            local spec_support = require("remotelibrary_spec_support")

            package.loaded["plugins/RemoteLibrary.koplugin/main.lua"] = nil
            local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")

            local original_showFileDialog_called = false
            local mock_fc = {
                path = "/books",
                getList = function() return {}, {} end,
                getMenuItemMandatory = function() return "" end,
                changeToPath = function() end,
                onFileSelect = function() end,
                showFileDialog = function()
                    original_showFileDialog_called = true
                    return false
                end,
                ui = {},
            }
            local plugin_instance = spec_support.mockInstance(RemoteLibrary, {
                ui = { menu = { registerToMainMenu = function() end } },
                settings = { readSetting = function() return nil end },
                loadSettings = function() end
            })

            plugin_instance:hookFileChooser(mock_fc)

            local local_item = { is_proxy = false, is_file = true, text = "book.epub" }
            local res = mock_fc:showFileDialog(local_item)

            assert.is_true(original_showFileDialog_called)
            assert.is_false(res)
        end)

        it("patches lfs.dir and lfs.attributes globally and maps virtual files/folders", function()
            local lfs = require("libs/libkoreader-lfs")

            package.loaded["plugins/RemoteLibrary.koplugin/main.lua"] = nil
            local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")

            local plugin_instance = setmetatable({
                ui = { menu = { registerToMainMenu = function() end } },
                settings = { readSetting = function() return nil end },
                loadSettings = function() end
            }, { __index = RemoteLibrary })

            plugin_instance:init()

            -- Let's test listing /books (home_dir is /books)
            local files = {}
            local ok, iter, dir_obj = pcall(lfs.dir, "/books")
            assert.is_true(ok)
            for entry in iter, dir_obj do
                if entry ~= "." and entry ~= ".." then
                    table.insert(files, entry)
                end
            end
            
            local has_book = false
            local has_folder = false
            for _, entry in ipairs(files) do
                if entry == "remote_book.epub" then has_book = true end
                if entry == "remote_folder" then has_folder = true end
            end
            assert.is_true(has_book)
            assert.is_true(has_folder)

            -- Check lfs.attributes
            local attr_file = lfs.attributes("/books/remote_book.epub")
            assert.is_table(attr_file)
            assert.equals("file", attr_file.mode)
            assert.equals(1024, attr_file.size)

            local attr_dir = lfs.attributes("/books/remote_folder")
            assert.is_table(attr_dir)
            assert.equals("directory", attr_dir.mode)
        end)

        it("intercepts ReaderUI:showReader for virtual files and triggers download", function()
            local UIManager = require("ui/uimanager")
            local original_show = UIManager.show
            local dialog_shown = nil
            UIManager.show = function(self, widget)
                dialog_shown = widget
            end

            local original_showReader_called = false
            local mock_ReaderUI = {
                showReader = function(self_r, file)
                    original_showReader_called = true
                end
            }
            package.loaded["apps/reader/readerui"] = mock_ReaderUI

            -- Reload plugin to apply hook on mock_ReaderUI
            package.loaded["plugins/RemoteLibrary.koplugin/main.lua"] = nil
            local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")

            local plugin_instance = setmetatable({
                ui = {
                    menu = { registerToMainMenu = function() end },
                    cloudstorage = {
                        getProviders = function() end,
                        loadSettings = function() end,
                        providers = {
                            webdav = {
                                run = function(callback) callback() end,
                                downloadFile = function() return 200 end
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

            local lfs = require("libs/libkoreader-lfs")
            lfs._remotelibrary_patched = nil

            plugin_instance:init()

            -- Let's call the patched showReader
            mock_ReaderUI.showReader(mock_ReaderUI, "/books/remote_book.epub")

            -- It should show download confirm dialog
            assert.is_not_nil(dialog_shown)
            assert.equals("Would you like to download remote_book.epub?", dialog_shown.text)

            -- Simulate clicking "Download"
            dialog_shown.ok_callback()

            -- Verify it successfully downloaded and then called original showReader
            assert.is_true(original_showReader_called)

            UIManager.show = original_show
            package.loaded["apps/reader/readerui"] = nil
        end)

        it("handles symlinked home_dir and virtual subdirectories properly", function()
            local lfs = require("libs/libkoreader-lfs")
            local ffiUtil = require("ffi/util")
            local original_realpath = ffiUtil.realpath

            -- Mock realpath to simulate /books being a symlink to /Users/dani/books
            ffiUtil.realpath = function(path)
                if path == "/books" then
                    return "/Users/dani/books"
                elseif path == "/books/remote_folder" then
                    return nil -- virtual folder, does not exist on disk
                elseif path == "/Users/dani/books" then
                    return "/Users/dani/books"
                end
                return original_realpath(path)
            end

            -- Now set home_dir to /books
            _G.G_reader_settings = {
                readSetting = function(self, key, default)
                    if key == "home_dir" then
                        return "/books"
                    end
                    return default
                end,
                nilOrTrue = function(self, key) return true end,
                isTrue = function(self, key) return false end,
                isFalse = function(self, key) return false end
            }
            _G.Device = { home_dir = "/books" }

            package.loaded["plugins/RemoteLibrary.koplugin/main.lua"] = nil
            local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")

            local plugin_instance = setmetatable({
                ui = { menu = { registerToMainMenu = function() end } },
                settings = { readSetting = function() return nil end },
                loadSettings = function() end
            }, { __index = RemoteLibrary })

            plugin_instance:init()

            -- We check that lfs.attributes for /books/remote_folder is recognized as directory
            local attr = lfs.attributes("/books/remote_folder")

            -- Cleanup first
            ffiUtil.realpath = original_realpath

            assert.is_table(attr)
            assert.equals("directory", attr.mode)
        end)

        it("handles ffiUtil.realpath on virtual paths", function()
            local ffiUtil = require("ffi/util")
            local original_realpath = ffiUtil.realpath

            -- Mock realpath to simulate /books being a symlink to /Users/dani/books
            ffiUtil.realpath = function(path)
                if path == "/books" then
                    return "/Users/dani/books"
                elseif path == "/books/remote_folder" then
                    return nil -- virtual folder, does not exist on disk
                elseif path == "/Users/dani/books" then
                    return "/Users/dani/books"
                end
                return original_realpath(path)
            end

            -- Now set home_dir to /books
            _G.G_reader_settings = {
                readSetting = function(self, key, default)
                    if key == "home_dir" then
                        return "/books"
                    end
                    return default
                end,
                nilOrTrue = function(self, key) return true end,
                isTrue = function(self, key) return false end,
                isFalse = function(self, key) return false end
            }
            _G.Device = { home_dir = "/books" }

            package.loaded["plugins/RemoteLibrary.koplugin/main.lua"] = nil
            local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")

            local plugin_instance = setmetatable({
                ui = { menu = { registerToMainMenu = function() end } },
                settings = { readSetting = function() return nil end },
                loadSettings = function() end
            }, { __index = RemoteLibrary })

            plugin_instance:init()

            -- We check that ffiUtil.realpath resolves the virtual path to its correct resolved ancestor-based path
            local resolved = ffiUtil.realpath("/books/remote_folder")
            local resolved_parent = ffiUtil.realpath("/books/remote_folder/..")

            -- Cleanup first
            ffiUtil.realpath = original_realpath

            assert.equals("/Users/dani/books/remote_folder", resolved)
            assert.equals("/Users/dani/books", resolved_parent)
        end)

        it("creates physical parent directory during download for virtual nested files", function()
            local lfs = require("libs/libkoreader-lfs")
            local mkdir_called = nil
            local original_mkdir = lfs.mkdir
            lfs.mkdir = function(path)
                mkdir_called = path
                return true
            end

            package.loaded["plugins/RemoteLibrary.koplugin/main.lua"] = nil
            local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")

            local plugin_instance = setmetatable({
                ui = {
                    menu = { registerToMainMenu = function() end },
                    cloudstorage = {
                        getProviders = function() end,
                        loadSettings = function() end,
                        providers = {
                            webdav = {
                                run = function(callback) callback() end,
                                downloadFile = function() return 200 end
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

            plugin_instance:init()

            local item = {
                text = "nested_book.epub",
                path = "/books/remote_folder/nested_book.epub",
                url = "/remote_folder/nested_book.epub"
            }

            plugin_instance:downloadRemoteFile(item, function(success)
                -- we don't strict-assert success if progressbar mocks are missing, but mkdir should be called
            end)

            lfs.mkdir = original_mkdir

            assert.equals("/books/remote_folder/", mkdir_called)
        end)

        it("patches BookInfo:getDocProps to intercept proxy files", function()
            package.path = package.path .. ";plugins/RemoteLibrary.koplugin/spec/unit/?.lua"
            local spec_support = require("remotelibrary_spec_support")

            local BookInfo = require("apps/filemanager/filemanagerbookinfo")
            local original_getDocProps = BookInfo.getDocProps
            local restore_flag = spec_support.patch(BookInfo, "_remotelibrary_patched", nil)

            package.loaded["plugins/RemoteLibrary.koplugin/main.lua"] = nil
            local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")
            local plugin_instance = spec_support.mockInstance(RemoteLibrary, {
                ui = { menu = { registerToMainMenu = function() end } },
                settings = { readSetting = function() return nil end },
                loadSettings = function() end
            })

            plugin_instance:init()
            local props = BookInfo.getDocProps(nil, "/books/remote_book.epub")

            BookInfo.getDocProps = original_getDocProps
            restore_flag()

            assert.is_table(props)
            assert.equals("remote_book", props.display_title)
        end)

        it("patches BookInfoManager:getDocProps to intercept proxy files", function()
            package.path = package.path .. ";plugins/RemoteLibrary.koplugin/spec/unit/?.lua"
            local spec_support = require("remotelibrary_spec_support")

            local BookInfoManager = require("bookinfomanager")
            local original_getDocProps = BookInfoManager.getDocProps
            local restore_flag = spec_support.patch(BookInfoManager, "_remotelibrary_patched", nil)

            package.loaded["plugins/RemoteLibrary.koplugin/main.lua"] = nil
            local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")
            local plugin_instance = spec_support.mockInstance(RemoteLibrary, {
                ui = { menu = { registerToMainMenu = function() end } },
                settings = { readSetting = function() return nil end },
                loadSettings = function() end
            })

            plugin_instance:init()
            local props = BookInfoManager:getDocProps("/books/remote_book.epub")

            BookInfoManager.getDocProps = original_getDocProps
            restore_flag()

            assert.is_table(props)
            assert.equals("remote_book", props.display_title)
        end)

        it("falls through to original getDocProps for a locally-deleted, non-remote file in BookInfo:getDocProps", function()
            package.path = package.path .. ";plugins/RemoteLibrary.koplugin/spec/unit/?.lua"
            local spec_support = require("remotelibrary_spec_support")

            local BookInfo = require("apps/filemanager/filemanagerbookinfo")
            local restore_flag = spec_support.patch(BookInfo, "_remotelibrary_patched", nil)

            local original_called = false
            local restore_getDocProps = spec_support.patch(BookInfo, "getDocProps", function(...)
                original_called = true
                return { display_title = "original" }
            end)

            package.loaded["plugins/RemoteLibrary.koplugin/main.lua"] = nil
            local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")
            local plugin_instance = spec_support.mockInstance(RemoteLibrary, {
                ui = { menu = { registerToMainMenu = function() end } },
                settings = { readSetting = function() return nil end },
                loadSettings = function() end
            })

            plugin_instance:init()
            local props = BookInfo.getDocProps(nil, "/books/not_remote.epub")

            restore_getDocProps()
            restore_flag()

            assert.is_true(original_called)
            assert.is_table(props)
            assert.equals("original", props.display_title)
        end)

        it("falls through to original getBookInfo for a locally-deleted, non-remote file in BookInfoManager:getBookInfo", function()
            package.path = package.path .. ";plugins/RemoteLibrary.koplugin/spec/unit/?.lua"
            local spec_support = require("remotelibrary_spec_support")

            local BookInfoManager = require("bookinfomanager")
            local restore_flag = spec_support.patch(BookInfoManager, "_remotelibrary_patched", nil)

            local original_called = false
            local restore_getBookInfo = spec_support.patch(BookInfoManager, "getBookInfo", function(...)
                original_called = true
                return { marker = "original" }
            end)

            package.loaded["plugins/RemoteLibrary.koplugin/main.lua"] = nil
            local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")
            local plugin_instance = spec_support.mockInstance(RemoteLibrary, {
                ui = { menu = { registerToMainMenu = function() end } },
                settings = { readSetting = function() return nil end },
                loadSettings = function() end
            })

            plugin_instance:init()
            local info = BookInfoManager:getBookInfo("/books/not_remote.epub")

            restore_getBookInfo()
            restore_flag()

            assert.is_true(original_called)
            assert.is_table(info)
            assert.equals("original", info.marker)
        end)

        it("falls through to original getDocProps for a locally-deleted, non-remote file in BookInfoManager:getDocProps", function()
            package.path = package.path .. ";plugins/RemoteLibrary.koplugin/spec/unit/?.lua"
            local spec_support = require("remotelibrary_spec_support")

            local BookInfoManager = require("bookinfomanager")
            local restore_flag = spec_support.patch(BookInfoManager, "_remotelibrary_patched", nil)

            local original_called = false
            local restore_getDocProps = spec_support.patch(BookInfoManager, "getDocProps", function(...)
                original_called = true
                return { marker = "original" }
            end)

            package.loaded["plugins/RemoteLibrary.koplugin/main.lua"] = nil
            local RemoteLibrary = dofile("plugins/RemoteLibrary.koplugin/main.lua")
            local plugin_instance = spec_support.mockInstance(RemoteLibrary, {
                ui = { menu = { registerToMainMenu = function() end } },
                settings = { readSetting = function() return nil end },
                loadSettings = function() end
            })

            plugin_instance:init()
            local props = BookInfoManager:getDocProps("/books/not_remote.epub")

            restore_getDocProps()
            restore_flag()

            assert.is_true(original_called)
            assert.is_table(props)
            assert.equals("original", props.marker)
        end)
    end)
end)
