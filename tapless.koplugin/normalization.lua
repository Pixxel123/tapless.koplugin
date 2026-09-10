local logger = require("logger")
local util = require("util")

local Normalization = {
    DEFAULT_PROFILE = "latin-extended-v1",
}
Normalization.__index = Normalization

function Normalization:new(plugin_dir)
    local instance = setmetatable({
        plugin_dir = plugin_dir or ".",
        profiles = {},
    }, self)
    instance:_loadProfiles()
    return instance
end

function Normalization:_loadProfiles()
    local path = self.plugin_dir .. "/normalization_profiles.tsv"
    local file = io.open(path, "r")
    if not file then
        logger.warn("swype mvp normalization profiles missing", path)
        return
    end
    for line in file:lines() do
        if string.sub(line, 1, 1) ~= "#" then
            local profile, character, normalized = line:match(
                "^([a-z][a-z0-9-]*)\t(.+)\t([a-z])$")
            if profile and character and normalized then
                self.profiles[profile] = self.profiles[profile] or {}
                self.profiles[profile][character] = normalized
            end
        end
    end
    file:close()
end

function Normalization:splitChars(text)
    return util.splitToChars(text or "")
end

function Normalization:normalizeChar(char, profile)
    char = char or ""
    local map = self.profiles[profile]
        or self.profiles[self.DEFAULT_PROFILE]
    char = map and map[char] or char
    if char:match("^[A-Z]$") then
        return string.lower(char)
    end
    if char:match("^[a-z]$") then
        return char
    end
end

function Normalization:normalizeText(text, profile)
    if type(text) ~= "string" then
        return ""
    end
    local normalized = {}
    for _, char in ipairs(self:splitChars(text)) do
        char = self:normalizeChar(char, profile)
        if char then
            table.insert(normalized, char)
        end
    end
    return table.concat(normalized)
end

return Normalization
