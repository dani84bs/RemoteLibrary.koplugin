describe("Scanner", function()
    local orig_path
    local spec_support

    setup(function()
        orig_path = package.path
        package.path = "plugins/RemoteLibrary.koplugin/?.lua;"
            .. "plugins/RemoteLibrary.koplugin/spec/unit/?.lua;"
            .. package.path
        require("commonrequire")
        spec_support = require("remotelibrary_spec_support")
    end)

    teardown(function()
        package.path = orig_path
    end)

    local function neverCancel()
        return false
    end

    local function loadScanner()
        package.loaded["plugins/RemoteLibrary.koplugin/scanner.lua"] = nil
        return dofile("plugins/RemoteLibrary.koplugin/scanner.lua")
    end

    it("crawls the provider folder-by-folder and reports the built tree", function()
        local UIManager = require("ui/uimanager")
        local restore_nextTick = spec_support.patch(UIManager, "nextTick", function(self, callback) callback() end)

        local Scanner = loadScanner()

        local list_folder_calls = 0
        local provider = {
            run = function(callback) callback() end,
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

        local done_tree, done_folders, done_files, done_cancelled
        Scanner.scan(provider, { type = "webdav", url = "/books" }, {
            on_progress = function() end,
            on_done = function(tree, folder_count, file_count, cancelled)
                done_tree, done_folders, done_files, done_cancelled = tree, folder_count, file_count, cancelled
            end,
        }, neverCancel)

        restore_nextTick()

        assert.equals(2, list_folder_calls)
        assert.equals(1, done_folders)
        assert.equals(2, done_files)
        assert.is_false(done_cancelled)
        assert.equals("book1.epub", done_tree.files[1].name)
        assert.equals("book2.epub", done_tree.folders["fiction"].files[1].name)
    end)

    it("reports progress before each folder fetch", function()
        local UIManager = require("ui/uimanager")
        local restore_nextTick = spec_support.patch(UIManager, "nextTick", function(self, callback) callback() end)

        local Scanner = loadScanner()

        local provider = {
            run = function(callback) callback() end,
            listFolder = function(url)
                if url == "/books" then
                    return { { text = "fiction", is_folder = true, url = "/books/fiction" } }
                end
                return {}
            end
        }

        local progress_calls = {}
        Scanner.scan(provider, { type = "webdav", url = "/books" }, {
            on_progress = function(folder_count, file_count)
                table.insert(progress_calls, { folder_count, file_count })
            end,
            on_done = function() end,
        }, neverCancel)

        restore_nextTick()

        assert.same({ { 0, 0 }, { 1, 0 } }, progress_calls)
    end)

    it("continues the per-folder crawl when listFolder fails for one folder", function()
        local UIManager = require("ui/uimanager")
        local restore_nextTick = spec_support.patch(UIManager, "nextTick", function(self, callback) callback() end)

        local Scanner = loadScanner()

        local list_folder_calls = 0
        local provider = {
            run = function(callback) callback() end,
            listFolder = function(url)
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

        local done_folders, done_files
        Scanner.scan(provider, { type = "webdav", url = "/books" }, {
            on_progress = function() end,
            on_done = function(tree, folder_count, file_count)
                done_folders, done_files = folder_count, file_count
            end,
        }, neverCancel)

        restore_nextTick()

        assert.equals(3, list_folder_calls)
        assert.equals(2, done_folders)
        assert.equals(1, done_files)
    end)

    it("calls on_done with cancelled=true and zero counts when cancelled before the scan starts", function()
        local Scanner = loadScanner()

        local provider = {
            run = function() error("should not be called") end,
            listFolder = function() error("should not be called") end,
        }

        local done_folders, done_files, done_cancelled
        Scanner.scan(provider, { type = "webdav", url = "/books" }, {
            on_progress = function() end,
            on_done = function(tree, folder_count, file_count, cancelled)
                done_folders, done_files, done_cancelled = folder_count, file_count, cancelled
            end,
        }, function() return true end)

        assert.equals(0, done_folders)
        assert.equals(0, done_files)
        assert.is_true(done_cancelled)
    end)

    it("calls on_done with cancelled=true and partial counts when cancelled mid-crawl", function()
        local UIManager = require("ui/uimanager")
        local restore_nextTick = spec_support.patch(UIManager, "nextTick", function(self, callback) callback() end)

        local Scanner = loadScanner()

        local cancel_after_first_folder = false
        local provider = {
            run = function(callback) callback() end,
            listFolder = function(url)
                if url == "/books" then
                    cancel_after_first_folder = true
                    return {
                        { text = "book1.epub", is_file = true, url = "/books/book1.epub", filesize = 1024 },
                        { text = "fiction", is_folder = true, url = "/books/fiction" }
                    }
                end
                return {}
            end
        }

        local done_tree, done_folders, done_files, done_cancelled
        Scanner.scan(provider, { type = "webdav", url = "/books" }, {
            on_progress = function() end,
            on_done = function(tree, folder_count, file_count, cancelled)
                done_tree, done_folders, done_files, done_cancelled = tree, folder_count, file_count, cancelled
            end,
        }, function() return cancel_after_first_folder end)

        restore_nextTick()

        assert.equals(1, done_folders)
        assert.equals(1, done_files)
        assert.is_true(done_cancelled)
        assert.equals("book1.epub", done_tree.files[1].name)
    end)

    it("skips the WebDAV deep-scan fast path when address is not set", function()
        local UIManager = require("ui/uimanager")
        local restore_nextTick = spec_support.patch(UIManager, "nextTick", function(self, callback) callback() end)

        local restore_http = spec_support.patch(package.loaded, "socket.http", {
            request = function(req)
                error("should not be called")
            end
        })

        local Scanner = loadScanner()

        local list_folder_calls = 0
        local provider = {
            run = function(callback) callback() end,
            listFolder = function(url)
                list_folder_calls = list_folder_calls + 1
                return {}
            end
        }

        Scanner.scan(provider, { type = "webdav", url = "/books" }, {
            on_progress = function() end,
            on_done = function() end,
        }, neverCancel)

        restore_nextTick()
        restore_http()

        assert.equals(1, list_folder_calls)
    end)

    it("uses a single Depth:infinity PROPFIND request when address is configured", function()
        local UIManager = require("ui/uimanager")
        local restore_nextTick = spec_support.patch(UIManager, "nextTick", function(self, callback) callback() end)

        local http_request_calls = 0
        local restore_http = spec_support.patch(package.loaded, "socket.http", {
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
        })

        local Scanner = loadScanner()

        local list_folder_calls = 0
        local provider = {
            run = function(callback) callback() end,
            listFolder = function() list_folder_calls = list_folder_calls + 1 return {} end
        }

        local done_tree, done_folders, done_files, done_cancelled
        Scanner.scan(provider, { type = "webdav", url = "/books", address = "https://example.com/dav" }, {
            on_progress = function() end,
            on_done = function(tree, folder_count, file_count, cancelled)
                done_tree, done_folders, done_files, done_cancelled = tree, folder_count, file_count, cancelled
            end,
        }, neverCancel)

        restore_nextTick()
        restore_http()

        assert.equals(1, http_request_calls)
        assert.equals(0, list_folder_calls)
        assert.equals(1, done_folders)
        assert.equals(2, done_files)
        assert.is_false(done_cancelled)
        assert.equals("book1.epub", done_tree.files[1].name)
        assert.equals("book2.epub", done_tree.folders["fiction"].files[1].name)
    end)

    it("falls back to the per-folder crawl when the PROPFIND deep-scan fails", function()
        local UIManager = require("ui/uimanager")
        local restore_nextTick = spec_support.patch(UIManager, "nextTick", function(self, callback) callback() end)

        local restore_http = spec_support.patch(package.loaded, "socket.http", {
            request = function(req)
                -- server rejects Depth: infinity
                return 1, 403, {}, "HTTP/1.1 403 Forbidden"
            end
        })

        local Scanner = loadScanner()

        local list_folder_calls = 0
        local provider = {
            run = function(callback) callback() end,
            listFolder = function() list_folder_calls = list_folder_calls + 1 return {} end
        }

        Scanner.scan(provider, { type = "webdav", url = "/books", address = "https://example.com/dav" }, {
            on_progress = function() end,
            on_done = function() end,
        }, neverCancel)

        restore_nextTick()
        restore_http()

        assert.equals(1, list_folder_calls)
    end)

    it("falls back to the per-folder crawl when PROPFIND returns 401", function()
        local UIManager = require("ui/uimanager")
        local restore_nextTick = spec_support.patch(UIManager, "nextTick", function(self, callback) callback() end)

        local restore_http = spec_support.patch(package.loaded, "socket.http", {
            request = function(req)
                return 1, 401, {}, "HTTP/1.1 401 Unauthorized"
            end
        })

        local Scanner = loadScanner()

        local list_folder_calls = 0
        local provider = {
            run = function(callback) callback() end,
            listFolder = function() list_folder_calls = list_folder_calls + 1 return {} end
        }

        Scanner.scan(provider, { type = "webdav", url = "/books", address = "https://example.com/dav" }, {
            on_progress = function() end,
            on_done = function() end,
        }, neverCancel)

        restore_nextTick()
        restore_http()

        assert.equals(1, list_folder_calls)
    end)

    it("does not add garbage entries when PROPFIND returns unparseable XML", function()
        local UIManager = require("ui/uimanager")
        local restore_nextTick = spec_support.patch(UIManager, "nextTick", function(self, callback) callback() end)

        local restore_http = spec_support.patch(package.loaded, "socket.http", {
            request = function(req)
                req.sink("this is not xml at all, just garbage <<< >>>")
                req.sink(nil)
                return 1, 207, { ["content-type"] = "application/xml" }, "HTTP/1.1 207 Multi-Status"
            end
        })

        local Scanner = loadScanner()

        local list_folder_calls = 0
        local provider = {
            run = function(callback) callback() end,
            listFolder = function() list_folder_calls = list_folder_calls + 1 return {} end
        }

        local done_tree, done_folders, done_files
        Scanner.scan(provider, { type = "webdav", url = "/books", address = "https://example.com/dav" }, {
            on_progress = function() end,
            on_done = function(tree, folder_count, file_count)
                done_tree, done_folders, done_files = tree, folder_count, file_count
            end,
        }, neverCancel)

        restore_nextTick()
        restore_http()

        -- Malformed XML that doesn't match the expected response pattern yields no
        -- entries, so the deep-scan "succeeds" with an empty tree rather than crashing.
        assert.equals(0, list_folder_calls)
        assert.equals(0, done_folders)
        assert.equals(0, done_files)
        assert.same({}, done_tree.files)
    end)

    it("falls back to the per-folder crawl when the PROPFIND request itself fails", function()
        local UIManager = require("ui/uimanager")
        local restore_nextTick = spec_support.patch(UIManager, "nextTick", function(self, callback) callback() end)

        local restore_http = spec_support.patch(package.loaded, "socket.http", {
            request = function(req)
                error("connection timed out")
            end
        })

        local Scanner = loadScanner()

        local list_folder_calls = 0
        local provider = {
            run = function(callback) callback() end,
            listFolder = function() list_folder_calls = list_folder_calls + 1 return {} end
        }

        Scanner.scan(provider, { type = "webdav", url = "/books", address = "https://example.com/dav" }, {
            on_progress = function() end,
            on_done = function() end,
        }, neverCancel)

        restore_nextTick()
        restore_http()

        assert.equals(1, list_folder_calls)
    end)
end)
