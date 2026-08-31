package.path = package.path .. ";plugins/RemoteLibrary.koplugin/spec/e2e/?.lua"
local support = require("remotelibrary_e2e_spec_support")

describe("RemoteLibrary e2e reload failures", function()
    local UIManager
    local filemanager, remotelibrary

    setup(function()
        require("commonrequire")
        UIManager = require("ui/uimanager")
    end)

    before_each(function()
        support.resetRemoteLibraryState()
        filemanager, _, remotelibrary = support.newFileManager()
        remotelibrary:loadSettings()
    end)

    after_each(function()
        support.closeFileManager(filemanager)
    end)

    local function reloadAndCapture()
        local message
        local original_show = UIManager.show
        UIManager.show = function(self, widget)
            if widget.text then message = widget.text end
            return original_show(self, widget)
        end

        remotelibrary:reloadRemoteLibrary()
        support.settleUntil(function()
            return message and message:match("^Reload") ~= nil
        end)
        UIManager.show = original_show
        return message
    end

    it("silently reports zero results when the WebDAV server is unreachable", function()
        remotelibrary.settings:saveSetting(
            "cloudstorage_dir",
            support.webdavConfig({ address = "http://127.0.0.1:18199" }) -- nothing listens here
        )

        local message = reloadAndCapture()

        assert.matches("Reload complete: 0 folders and 0 files mapped%.", message)
    end)

    it("silently reports zero results when credentials are rejected by the real server", function()
        remotelibrary.settings:saveSetting(
            "cloudstorage_dir",
            support.webdavConfig({ password = "wrong-password" })
        )

        local message = reloadAndCapture()

        assert.matches("Reload complete: 0 folders and 0 files mapped%.", message)
    end)

    it("does not crash when the server returns malformed PROPFIND XML", function()
        local stub = support.startMalformedPropfindStub()

        remotelibrary.settings:saveSetting(
            "cloudstorage_dir",
            support.webdavConfig({ address = stub.address })
        )

        local message = reloadAndCapture()

        stub.stop()

        assert.matches("Reload complete: 0 folders and 0 files mapped%.", message)
    end)
end)
