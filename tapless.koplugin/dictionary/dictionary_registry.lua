-- Central registry for bundled and downloaded Tapless dictionary packages.

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")

local source = debug.getinfo(1, "S").source
local DEFAULT_PLUGIN_DIR = source:match(
    "^@(.+)/dictionary/dictionary_registry%.lua$") or "."
local MAX_MANIFEST_BYTES = 64 * 1024
local DEFAULT_NORMALIZATION_PROFILE = "latin-extended-v1"
local REQUIRED_FILES = {
    manifest = "manifest.tsv",
    bucket_data = "words.buckets.tsv",
    bucket_index = "words.buckets.idx",
    popular_data = "words.popular.tsv",
    popular_index = "words.popular.idx",
}
-- The word-pair table: which words tend to follow which. A dictionary
-- works without it; it is used only when both files are there.
local PAIR_FILES = {
    pairs_data = "words.pairs.tsv",
    pairs_index = "words.pairs.idx",
}

local Registry = {}

-- Listing the dictionaries reads every manifest from disk, which is slow
-- on e-readers, and it is needed often. The list is kept until one of the
-- dictionary folders changes or invalidate() is called.
local list_cache = {}

local function isDirectory(path)
    return path and lfs.attributes(path, "mode") == "directory"
end

local function isSafeLanguage(value)
    return type(value) == "string"
        and value:match("^[a-z][a-z0-9-]*$") ~= nil
end

local function isSafeKeyboardLayout(value)
    return type(value) == "string"
        and value:match("^[A-Za-z0-9_]+$") ~= nil
end

local function readFile(path, max_bytes)
    local file = io.open(path, "rb")
    if not file then
        return nil, "Cannot open file"
    end
    local data = file:read(max_bytes + 1)
    file:close()
    if data and #data > max_bytes then
        return nil, "File is too large"
    end
    return data
end

function Registry:isSafeId(value)
    return isSafeLanguage(value)
end

function Registry:externalRoot()
    return DataStorage:getDataDir() .. "/swype/dictionaries"
end

function Registry:parseManifest(path)
    local data, err = readFile(path, MAX_MANIFEST_BYTES)
    if not data then
        return nil, err
    end
    local manifest = {}
    for line in data:gmatch("[^\r\n]+") do
        local key, value = line:match("^([^\t]+)\t(.*)$")
        if key and value and string.sub(key, 1, 1) ~= "#" then
            manifest[key] = value
        end
    end
    return manifest
end

function Registry:hasRequiredFiles(path)
    if not isDirectory(path) then
        return false
    end
    for _, filename in pairs(REQUIRED_FILES) do
        if not lfs.attributes(path .. "/" .. filename) then
            return false
        end
    end
    return true
end

function Registry:_readDescriptor(path, id, bundled)
    if not self:hasRequiredFiles(path) then
        return nil
    end
    local manifest = self:parseManifest(path .. "/" .. REQUIRED_FILES.manifest)
    if not manifest or (manifest.id and manifest.id ~= id) then
        return nil
    end

    local language = isSafeLanguage(manifest.language) and manifest.language or id
    local source_language = isSafeLanguage(manifest.source_language)
        and manifest.source_language or language
    local data_language = isSafeLanguage(manifest.data_language)
        and manifest.data_language or source_language
    local keyboard_layout = isSafeKeyboardLayout(manifest.keyboard_layout)
        and manifest.keyboard_layout or nil
    local normalization_profile = isSafeLanguage(manifest.normalization_profile)
        and manifest.normalization_profile or DEFAULT_NORMALIZATION_PROFILE

    local files = {}
    for role, filename in pairs(REQUIRED_FILES) do
        files[role] = path .. "/" .. filename
    end
    if lfs.attributes(path .. "/" .. PAIR_FILES.pairs_data)
            and lfs.attributes(path .. "/" .. PAIR_FILES.pairs_index) then
        for role, filename in pairs(PAIR_FILES) do
            files[role] = path .. "/" .. filename
        end
    end
    return {
        id = id,
        name = manifest.name or id,
        short_label = manifest.short_label,
        version = manifest.version or "?",
        format = tonumber(manifest.format or manifest.package_format) or 1,
        rows = tonumber(manifest.rows),
        language = language,
        source_language = source_language,
        data_language = data_language,
        keyboard_layout = keyboard_layout,
        normalization_profile = normalization_profile,
        path = path,
        bundled = bundled == true,
        files = files,
        manifest = manifest,
    }
end

function Registry:get(id, plugin_dir)
    if not self:isSafeId(id) then
        return nil
    end
    for _, descriptor in ipairs(self:list(plugin_dir)) do
        if descriptor.id == id then
            return descriptor
        end
    end
end

function Registry:invalidate()
    list_cache = {}
end

function Registry:isAvailable(id, plugin_dir)
    return self:get(id, plugin_dir) ~= nil
end

function Registry:list(plugin_dir)
    plugin_dir = plugin_dir or DEFAULT_PLUGIN_DIR
    local external_root = self:externalRoot()
    local bundled_root = plugin_dir .. "/dictionaries"
    local stamp = tostring(lfs.attributes(external_root, "modification"))
        .. "|" .. tostring(lfs.attributes(bundled_root, "modification"))
    local cached = list_cache[plugin_dir]
    if not cached or cached.stamp ~= stamp then
        cached = { stamp = stamp, list = self:_scan(external_root, bundled_root) }
        list_cache[plugin_dir] = cached
    end
    local copy = {}
    for index, descriptor in ipairs(cached.list) do
        copy[index] = descriptor
    end
    return copy
end

function Registry:_scan(external_root, bundled_root)
    local found = {}
    if isDirectory(external_root) then
        for id in lfs.dir(external_root) do
            if self:isSafeId(id) then
                local descriptor = self:_readDescriptor(
                    external_root .. "/" .. id, id, false)
                if descriptor then
                    found[id] = descriptor
                end
            end
        end
    end
    if isDirectory(bundled_root) then
        for id in lfs.dir(bundled_root) do
            if self:isSafeId(id) and not found[id] then
                local descriptor = self:_readDescriptor(
                    bundled_root .. "/" .. id, id, true)
                if descriptor then
                    found[id] = descriptor
                end
            end
        end
    end

    local result = {}
    for _, descriptor in pairs(found) do
        table.insert(result, descriptor)
    end
    table.sort(result, function(left, right)
        if left.id == "en" then return true end
        if right.id == "en" then return false end
        if left.id == "pl" then return true end
        if right.id == "pl" then return false end
        return left.id < right.id
    end)
    return result
end

function Registry:shortLabel(id, plugin_dir)
    local descriptor = self:get(id, plugin_dir)
    local label = descriptor and descriptor.short_label
    if type(label) == "string" and label:match("^[A-Za-z0-9][A-Za-z0-9_-]*$") then
        return string.upper(string.sub(label, 1, 3))
    end
    local base = type(id) == "string" and id:match("^([a-z]+)") or nil
    return string.upper(string.sub(base or "?", 1, 3))
end

return Registry
