local M = {}

-- Monkeypatches tbl[key] with value, returning a restore() that puts the
-- original back. Works for any table field (io.open, lfs.mkdir, UIManager
-- methods, package.loaded["socket.http"], ...).
function M.patch(tbl, key, value)
    local original = tbl[key]
    tbl[key] = value
    return function()
        tbl[key] = original
    end
end

-- Builds a plugin-instance double that falls back to RemoteLibrary via
-- __index, e.g. M.mockInstance(RemoteLibrary, { settings = ..., ui = ... }).
function M.mockInstance(RemoteLibrary, fields)
    return setmetatable(fields or {}, { __index = RemoteLibrary })
end

return M
