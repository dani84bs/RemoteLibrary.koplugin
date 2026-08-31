package.path = package.path .. ";plugins/RemoteLibrary.koplugin/spec/e2e/?.lua"
local support = require("remotelibrary_e2e_spec_support")

describe("RemoteLibrary e2e download failures", function()
    local filemanager, root_path, remotelibrary

    setup(function()
        require("commonrequire")
    end)

    before_each(function()
        support.resetRemoteLibraryState()
        filemanager, root_path, remotelibrary = support.newFileManager()

        remotelibrary:loadSettings()
        remotelibrary.settings:saveSetting("cloudstorage_dir", support.webdavConfig())
        remotelibrary:reloadRemoteLibrary()
        support.settleUntil(function()
            local lfs = require("libs/libkoreader-lfs")
            return lfs.original_attributes(
                require("datastorage"):getSettingsDir() .. "/remotelibrary_map.lua", "mode"
            ) == "file"
        end)
    end)

    after_each(function()
        support.closeFileManager(filemanager)
    end)

    -- On loopback, the OS typically delivers a whole small/medium payload
    -- into the kernel socket buffer before the client even starts reading
    -- it, so killing the server after the first ltn12 chunk can't reliably
    -- interrupt an in-flight transfer. Killing it just before the request
    -- opens is the deterministic version of the same real failure: the
    -- provider hits a dead server and must fail and clean up, exercising
    -- the real socket/timeout behavior mocks can't.
    it("reports failure and removes the partial file when the server is dead at download time", function()
        local items = filemanager.file_chooser:genItemTableFromPath(root_path)
        local proxy = support.findCloudProxy(items, "book.txt")
        assert.is_table(proxy)

        support.killSharedWebDavServer()

        local success
        remotelibrary:downloadRemoteFile(proxy, function(ok) success = ok end)

        support.restartSharedWebDavServer()

        assert.is_false(success)
        local lfs = require("libs/libkoreader-lfs")
        assert.is_nil(lfs.original_attributes(proxy.path, "mode"))
    end)
end)
