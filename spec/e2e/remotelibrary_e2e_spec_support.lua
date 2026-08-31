package.path = package.path .. ";plugins/RemoteLibrary.koplugin/spec/unit/?.lua"
local spec_support = require("remotelibrary_spec_support")

local M = {}

-- Distinct from the shared server (18109) and the dead-port fixture some
-- specs point at (18199), so none of the three ever collide.
local MALFORMED_STUB_PORT = 18200

-- Polls url until its HTTP status code satisfies matches(code), or gives
-- up after tries attempts. code is "000" (curl's own marker) when nothing
-- is listening yet/anymore.
local function waitForHttpCode(url, matches, tries)
    for _ = 1, (tries or 50) do
        local probe = io.popen(string.format("curl -s -o /dev/null -w '%%{http_code}' --max-time 1 %s", url))
        local code = probe:read("*l")
        probe:close()
        if matches(code) then return true end
        os.execute("sleep 0.1")
    end
    return false
end

-- Real WebDAV server config for cloudstorage_dir, built from the env vars
-- run_e2e_tests.sh exports (see REMOTELIBRARY_E2E_WEBDAV_* there).
function M.webdavConfig(overrides)
    local config = {
        name = "E2E WebDAV",
        type = "webdav",
        address = string.format(
            "http://%s:%s",
            os.getenv("REMOTELIBRARY_E2E_WEBDAV_HOST"),
            os.getenv("REMOTELIBRARY_E2E_WEBDAV_PORT")
        ),
        url = "",
        username = os.getenv("REMOTELIBRARY_E2E_WEBDAV_USERNAME"),
        password = os.getenv("REMOTELIBRARY_E2E_WEBDAV_PASSWORD"),
    }
    for k, v in pairs(overrides or {}) do
        config[k] = v
    end
    return config
end

-- Builds a real FileManager (with plugins, including cloudstorage and
-- RemoteLibrary, actually loaded via PluginLoader) rooted at a throwaway
-- home directory, and points G_reader_settings' home_dir at it so
-- RemoteLibrary's overlay hooks recognize it. Returns the FileManager, its
-- root_path, and the RemoteLibrary plugin instance registered on it.
function M.newFileManager()
    local DataStorage = require("datastorage")
    local Screen = require("device").screen
    local UIManager = require("ui/uimanager")
    local lfs = require("libs/libkoreader-lfs")
    local FileManager = require("apps/filemanager/filemanager")

    local root_path = DataStorage:getDataDir() .. "/remotelibrary_e2e_home"
    os.execute(string.format("rm -rf %q && mkdir -p %q", root_path, root_path))
    lfs.mkdir(root_path)

    G_reader_settings:saveSetting("home_dir", root_path)

    local filemanager = FileManager:new{
        dimen = Screen:getSize(),
        root_path = root_path,
    }
    UIManager:show(filemanager)

    -- PluginLoader names a plugin after its directory ("RemoteLibrary.koplugin"),
    -- overriding main.lua's own lowercase self.name; RemoteLibrary's own code
    -- checks both forms defensively, so this does too.
    local remotelibrary = filemanager.RemoteLibrary or filemanager.remotelibrary
    assert(remotelibrary, "RemoteLibrary plugin was not loaded onto the FileManager")

    return filemanager, root_path, remotelibrary
end

function M.closeFileManager(filemanager)
    filemanager:onClose()
    require("ui/uimanager"):quit()
end

-- Removes RemoteLibrary's own persisted settings/map so each spec starts
-- from a clean slate regardless of what a previous spec left behind.
function M.resetRemoteLibraryState()
    local DataStorage = require("datastorage")
    os.remove(DataStorage:getSettingsDir() .. "/remotelibrary.lua")
    os.remove(DataStorage:getSettingsDir() .. "/remotelibrary_map.lua")
end

-- Runs the UIManager loop forward until predicate() is true or we give up.
-- Needed because RemoteLibrary schedules its scan/download work via
-- UIManager:nextTick, which only advances when the loop is pumped.
function M.settleUntil(predicate, max_iterations)
    local UIManager = require("ui/uimanager")
    for _ = 1, (max_iterations or 50) do
        if predicate() then return true end
        UIManager:shiftScheduledTasksBy(-1e9)
        UIManager:setInputTimeout(0)
        UIManager:handleInput()
    end
    return predicate()
end

-- Runs remotelibrary:reloadRemoteLibrary(), capturing the InfoMessage text
-- it ends on (e.g. "Reload complete: ..."), via the same patch/restore
-- convention spec/unit uses (spec_support.patch), forwarding to the real
-- UIManager.show so the FileManager the e2e specs drive stays live.
function M.reloadAndCapture(remotelibrary, UIManager)
    local message
    local original_show = UIManager.show
    local restore_show = spec_support.patch(UIManager, "show", function(self, widget)
        if widget.text then message = widget.text end
        return original_show(self, widget)
    end)

    remotelibrary:reloadRemoteLibrary()
    M.settleUntil(function()
        return message and message:match("^Reload") ~= nil
    end)
    restore_show()

    return message
end

-- Finds the [Cloud]-prefixed proxy entry for name in a FileChooser item
-- table (as returned by FileChooser:genItemTableFromPath).
function M.findCloudProxy(items, name)
    for _, item in ipairs(items) do
        if item.text == "[Cloud] " .. name then return item end
    end
    return nil
end

-- Starts a throwaway Node HTTP server that answers every request with a
-- 200 and a deliberately broken PROPFIND body. webdav-cli can't be told to
-- emit malformed XML, so this stub exists purely to serve that one
-- response shape for the malformed-response spec, and is torn down by the
-- caller once that spec is done with it.
function M.startMalformedPropfindStub()
    local script_path = os.tmpname() .. ".js"
    local script = io.open(script_path, "w")
    script:write([[
const http = require("http");
const server = http.createServer((req, res) => {
    res.writeHead(200, { "Content-Type": "application/xml" });
    res.end("<this is not valid PROPFIND xml");
});
server.listen(]] .. MALFORMED_STUB_PORT .. [[, "127.0.0.1");
]])
    script:close()

    local launch = io.popen(string.format("node %q >/dev/null 2>&1 & echo $!", script_path))
    local pid = launch:read("*l")
    launch:close()

    waitForHttpCode(
        string.format("http://127.0.0.1:%d/", MALFORMED_STUB_PORT),
        function(code) return code == "200" end
    )

    return {
        address = string.format("http://127.0.0.1:%d", MALFORMED_STUB_PORT),
        stop = function()
            if pid then os.execute("kill " .. pid .. " 2>/dev/null") end
            os.remove(script_path)
        end,
    }
end

-- Kills the shared WebDAV server to simulate it dying during a download.
-- Used only by the download-failures spec, which restarts it (see
-- M.restartSharedWebDavServer) so spec files that happen to run afterwards
-- in the same harness invocation still see a live server, regardless of
-- run order.
function M.killSharedWebDavServer()
    local host = os.getenv("REMOTELIBRARY_E2E_WEBDAV_HOST")
    local port = os.getenv("REMOTELIBRARY_E2E_WEBDAV_PORT")
    -- Signaling the exported PID's process *group* from inside this test
    -- process (a descendant of a different shell than the one that
    -- started the server) is unreliable here; matching by command line is
    -- what run_e2e_tests.sh's own kill_stale_webdav() uses, and reliably
    -- takes down the whole npx/npm-exec/node tree.
    os.execute(string.format("pkill -9 -f 'webdav-cli --host %s --port %s '", host, port))
    local down = waitForHttpCode(
        string.format("http://%s:%s/", host, port),
        function(code) return code == "000" end,
        30
    )
    if not down then error("webdav-cli did not go down after kill") end
end

-- Restarts the shared WebDAV server against the same data directory
-- run_e2e_tests.sh originally seeded, after M.killSharedWebDavServer() has
-- taken it down.
function M.restartSharedWebDavServer()
    local host = os.getenv("REMOTELIBRARY_E2E_WEBDAV_HOST")
    local port = os.getenv("REMOTELIBRARY_E2E_WEBDAV_PORT")
    local username = os.getenv("REMOTELIBRARY_E2E_WEBDAV_USERNAME")
    local password = os.getenv("REMOTELIBRARY_E2E_WEBDAV_PASSWORD")
    local data_dir = os.getenv("REMOTELIBRARY_E2E_WEBDAV_DATA_DIR")
    assert(data_dir, "REMOTELIBRARY_E2E_WEBDAV_DATA_DIR not set; run via run_e2e_tests.sh")

    local cmd = string.format(
        "setsid npx --yes webdav-cli --host %s --port %s --username %s --password %s --path %q "
            .. ">/tmp/remotelibrary_e2e_webdav_restart.log 2>&1 & echo $!",
        host, port, username, password, data_dir
    )
    local launch = io.popen(cmd)
    launch:read("*l")
    launch:close()

    local up = waitForHttpCode(
        string.format("-u %s:%s -X PROPFIND http://%s:%s/", username, password, host, port),
        function(code) return code ~= nil and code:match("^2") ~= nil end
    )
    if not up then error("webdav-cli did not come back up after restart") end
end

return M
