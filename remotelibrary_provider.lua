local Provider = {}

-- Resolves the cloudstorage provider configured for cloudstorage_dir.
-- ui.cloudstorage is missing when called from a ReaderUI context (e.g.
-- downloading a proxy while reading), so this also checks
-- FileManager.instance.cloudstorage.
function Provider.resolve(ui, cloudstorage_dir)
    local cloudstorage = ui.cloudstorage
    if not cloudstorage then
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then
            cloudstorage = FileManager.instance.cloudstorage
        end
    end

    if not cloudstorage then
        return nil, "no_plugin"
    end

    cloudstorage:getProviders()
    cloudstorage:loadSettings()

    local provider = cloudstorage.providers[cloudstorage_dir.type]
    if not provider then
        return nil, "no_provider"
    end

    return provider
end

return Provider
