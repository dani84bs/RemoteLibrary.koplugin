describe("Provider", function()
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

    local function loadProvider()
        package.loaded["plugins/RemoteLibrary.koplugin/provider.lua"] = nil
        return dofile("plugins/RemoteLibrary.koplugin/provider.lua")
    end

    it("resolves the provider via ui.cloudstorage", function()
        local Provider = loadProvider()

        local webdav_provider = {}
        local ui = {
            cloudstorage = {
                getProviders = function() end,
                loadSettings = function() end,
                providers = { webdav = webdav_provider }
            }
        }

        local provider, reason = Provider.resolve(ui, { type = "webdav", url = "/books" })

        assert.equals(webdav_provider, provider)
        assert.is_nil(reason)
    end)

    it("falls back to FileManager.instance.cloudstorage when ui.cloudstorage is absent", function()
        local FileManager = require("apps/filemanager/filemanager")
        local Provider = loadProvider()

        local webdav_provider = {}
        FileManager.instance = {
            cloudstorage = {
                getProviders = function() end,
                loadSettings = function() end,
                providers = { webdav = webdav_provider }
            }
        }

        local provider, reason = Provider.resolve({}, { type = "webdav", url = "/books" })

        FileManager.instance = nil

        assert.equals(webdav_provider, provider)
        assert.is_nil(reason)
    end)

    it("returns nil, 'no_plugin' when the cloudstorage plugin isn't available anywhere", function()
        local FileManager = require("apps/filemanager/filemanager")
        local Provider = loadProvider()

        FileManager.instance = nil

        local provider, reason = Provider.resolve({}, { type = "webdav", url = "/books" })

        assert.is_nil(provider)
        assert.equals("no_plugin", reason)
    end)

    it("returns nil, 'no_provider' for a missing/unsupported provider type", function()
        local Provider = loadProvider()

        local ui = {
            cloudstorage = {
                getProviders = function() end,
                loadSettings = function() end,
                providers = {}
            }
        }

        local provider, reason = Provider.resolve(ui, { type = "unsupported_provider", url = "/books" })

        assert.is_nil(provider)
        assert.equals("no_provider", reason)
    end)
end)
