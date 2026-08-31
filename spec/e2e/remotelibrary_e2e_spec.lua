package.path = package.path .. ";plugins/RemoteLibrary.koplugin/spec/e2e/?.lua"
local support = require("remotelibrary_e2e_spec_support")

describe("RemoteLibrary e2e", function()
    local UIManager
    local filemanager, root_path, remotelibrary

    setup(function()
        require("commonrequire")
        UIManager = require("ui/uimanager")
    end)

    before_each(function()
        support.resetRemoteLibraryState()
        filemanager, root_path, remotelibrary = support.newFileManager()

        remotelibrary:loadSettings()
        remotelibrary.settings:saveSetting("cloudstorage_dir", support.webdavConfig())
    end)

    after_each(function()
        support.closeFileManager(filemanager)
    end)

    it("scans the real WebDAV server and overlays a [Cloud] proxy file", function()
        local reload_message = support.reloadAndCapture(remotelibrary, UIManager)

        assert.matches("Reload complete: %d+ folders and %d+ files mapped%.", reload_message)

        local items = filemanager.file_chooser:genItemTableFromPath(root_path)
        local proxy = support.findCloudProxy(items, "book.txt")
        assert.is_table(proxy)
        assert.is_true(proxy.is_proxy)
        assert.is_true(proxy.is_file)
    end)

    it("downloads a tapped [Cloud] file and clears its proxy", function()
        remotelibrary:reloadRemoteLibrary()
        support.settleUntil(function()
            local map_ok = pcall(function()
                return require("libs/libkoreader-lfs").original_attributes(
                    require("datastorage"):getSettingsDir() .. "/remotelibrary_map.lua", "mode"
                ) == "file"
            end)
            return map_ok
        end)

        local items = filemanager.file_chooser:genItemTableFromPath(root_path)
        local proxy = support.findCloudProxy(items, "book.txt")
        assert.is_table(proxy)

        local success
        remotelibrary:downloadRemoteFile(proxy, function(ok) success = ok end)

        assert.is_true(success)
        local lfs = require("libs/libkoreader-lfs")
        assert.equals("file", lfs.original_attributes(proxy.path, "mode"))

        local downloaded = io.open(proxy.path, "r")
        local content = downloaded:read("*a")
        downloaded:close()
        assert.matches("best of times", content)

        local items_after = filemanager.file_chooser:genItemTableFromPath(root_path)
        local reloaded
        for _, f in ipairs(items_after) do
            if f.path == proxy.path then reloaded = f end
        end
        assert.is_table(reloaded)
        assert.is_falsy(reloaded.is_proxy)
    end)
end)
