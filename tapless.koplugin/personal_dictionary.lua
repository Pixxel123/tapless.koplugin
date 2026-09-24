local DataStorage = require("datastorage")
local Utf8Proc = require("ffi/utf8proc")
local util = require("util")
local WordListFile = dofile((debug.getinfo(1, "S").source
    :match("^@(.+)/[^/]+%.lua$") or ".") .. "/word_list_file.lua")

local PersonalDictionary = {}
PersonalDictionary.__index = PersonalDictionary

local MAX_WORDS = 5000
local PERSONAL_FREQUENCY = 4500

function PersonalDictionary:new(normalization, dictionary_index, root)
    return setmetatable({
        normalization = assert(normalization),
        dictionary_index = assert(dictionary_index),
        root = root or (DataStorage:getDataDir() .. "/tapless/personal"),
        language = nil,
        profile = nil,
        words = nil,
        buckets = nil,
    }, self)
end

function PersonalDictionary:_validLanguage(language)
    return WordListFile.validLanguage(language)
end

function PersonalDictionary:_prepareWord(word, profile)
    if type(word) ~= "string" or word:find("[\t\r\n]") then
        return
    end
    local chars = self.normalization:splitChars(word)
    if #chars < 2 or #chars > 32 then
        return
    end
    for _, char in ipairs(chars) do
        if not self.normalization:normalizeChar(char, profile) then
            return
        end
    end
    local lowered = Utf8Proc.lowercase_dumb(word)
    local signature = self.normalization:normalizeText(lowered, profile)
    if #signature ~= #chars or not signature:match("^[a-z]+$") then
        return
    end
    return lowered, signature
end

function PersonalDictionary:_insert(buckets, word, signature)
    local key = string.sub(signature, 1, 1) .. string.sub(signature, -1)
    local bucket = buckets[key]
    if not bucket then
        bucket = self.dictionary_index:newBucket()
        buckets[key] = bucket
    end
    local line = table.concat({
        signature,
        word,
        tostring(PERSONAL_FREQUENCY),
        "en",
    }, "\t")
    local entry = self.dictionary_index:addBucketLine(bucket, line)
    if entry then
        entry.lang = nil
        entry.personal = true
    end
end

function PersonalDictionary:_buildBuckets(words, profile)
    local buckets = {}
    for word in pairs(words) do
        local prepared, signature = self:_prepareWord(word, profile)
        if prepared and signature then
            self:_insert(buckets, prepared, signature)
        end
    end
    return buckets
end

function PersonalDictionary:_path(language)
    return self.root .. "/" .. language .. ".txt"
end

function PersonalDictionary:_load(language, profile)
    local words = {}
    local count = 0
    local file = io.open(self:_path(language), "rb")
    if file then
        for line in file:lines() do
            if count >= MAX_WORDS then
                break
            end
            if #line <= 256 and string.sub(line, 1, 1) ~= "#" then
                local word = line:gsub("\r$", "")
                local prepared = self:_prepareWord(word, profile)
                if prepared and not words[prepared] then
                    words[prepared] = true
                    count = count + 1
                end
            end
        end
        file:close()
    end
    self.language = language
    self.profile = profile
    self.words = words
    self.buckets = self:_buildBuckets(words, profile)
end

function PersonalDictionary:_ensure(language, profile)
    if not self:_validLanguage(language) then
        return false
    end
    if self.language ~= language or self.profile ~= profile or not self.words then
        self:_load(language, profile)
    end
    return true
end

function PersonalDictionary:_save(words, language)
    return WordListFile.save(self:_path(language),
        "# Tapless personal dictionary v1", words,
        function() util.makePath(self.root) end, "personal dictionary")
end

function PersonalDictionary:prepareWord(word, profile)
    return self:_prepareWord(word, profile)
end

function PersonalDictionary:contains(language, word, profile)
    local prepared = self:_prepareWord(word, profile)
    if not prepared or not self:_ensure(language, profile) then
        return false
    end
    return self.words[prepared] == true
end

function PersonalDictionary:add(language, word, profile)
    local prepared = self:_prepareWord(word, profile)
    if not prepared or not self:_ensure(language, profile) then
        return nil, "Invalid word"
    end
    if self.words[prepared] then
        return true, "exists"
    end
    local count = 0
    local updated = {}
    for existing in pairs(self.words) do
        updated[existing] = true
        count = count + 1
    end
    if count >= MAX_WORDS then
        return nil, "Personal dictionary is full"
    end
    updated[prepared] = true
    local saved, err = self:_save(updated, language)
    if not saved then
        return nil, err
    end
    self.words = updated
    self.buckets = self:_buildBuckets(updated, profile)
    return true
end

function PersonalDictionary:remove(language, word, profile)
    local prepared = self:_prepareWord(word, profile)
    if not prepared or not self:_ensure(language, profile)
            or not self.words[prepared] then
        return false
    end
    local updated = {}
    for existing in pairs(self.words) do
        if existing ~= prepared then
            updated[existing] = true
        end
    end
    local saved, err = self:_save(updated, language)
    if not saved then
        return nil, err
    end
    self.words = updated
    self.buckets = self:_buildBuckets(updated, profile)
    return true
end

function PersonalDictionary:list(language, profile)
    if not self:_ensure(language, profile) then
        return {}
    end
    local words = {}
    for word in pairs(self.words) do
        table.insert(words, word)
    end
    table.sort(words)
    return words
end

function PersonalDictionary:getBucket(first, last, language, profile)
    if not self:_ensure(language, profile) then
        return
    end
    return self.buckets[(first or "") .. (last or "")]
end

return PersonalDictionary
