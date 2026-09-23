-- Words the user asked never to be suggested, one file per language.
local Utf8Proc = require("ffi/utf8proc")

local BlockedWords = {}
BlockedWords.__index = BlockedWords

-- root: folder for the lists; make_path(folder) creates it.
function BlockedWords:new(root, make_path)
    return setmetatable({
        root = root or (require("datastorage"):getDataDir()
            .. "/tapless/blocked"),
        make_path = make_path or function(path)
            require("util").makePath(path)
        end,
        words = {},
    }, self)
end

local function validLanguage(language)
    return type(language) == "string"
        and language:match("^[a-z][a-z0-9-]*$") ~= nil
end

local function key(word)
    if type(word) ~= "string" or word == "" or word:find("[\t\r\n]") then
        return
    end
    return Utf8Proc.lowercase_dumb(word)
end

function BlockedWords:_path(language)
    return self.root .. "/" .. language .. ".txt"
end

function BlockedWords:_words(language)
    local words = self.words[language]
    if words then
        return words
    end
    words = {}
    local file = io.open(self:_path(language), "rb")
    if file then
        for line in file:lines() do
            local word = key(line:gsub("\r$", ""))
            if word and word:sub(1, 1) ~= "#" then
                words[word] = true
            end
        end
        file:close()
    end
    self.words[language] = words
    return words
end

function BlockedWords:_save(language, words)
    self.make_path(self.root)
    local path = self:_path(language)
    local temporary = path .. ".tmp"
    local file = io.open(temporary, "wb")
    if not file then
        return nil, "Cannot write blocked words"
    end
    file:write("# Tapless blocked words v1\n")
    for _, word in ipairs(self:_sorted(words)) do
        file:write(word, "\n")
    end
    file:close()
    if not os.rename(temporary, path) then
        os.remove(temporary)
        return nil, "Cannot replace blocked words"
    end
    return true
end

function BlockedWords:_sorted(words)
    local list = {}
    for word in pairs(words) do
        list[#list + 1] = word
    end
    table.sort(list)
    return list
end

-- Called for every dictionary word a swipe is compared with, so it
-- returns early when the language has no blocked words.
function BlockedWords:contains(language, word)
    local words = self.words[language]
        or (validLanguage(language) and self:_words(language))
    if not words or next(words) == nil then
        return false
    end
    word = key(word)
    return word ~= nil and words[word] == true
end

function BlockedWords:list(language)
    if not validLanguage(language) then
        return {}
    end
    return self:_sorted(self:_words(language))
end

-- Returns true, or false (nothing to change) or nil and an error.
function BlockedWords:_change(language, word, blocked)
    word = key(word)
    if not word or not validLanguage(language) then
        return false
    end
    local words = self:_words(language)
    if (words[word] == true) == blocked then
        return false
    end
    local updated = {}
    for existing in pairs(words) do
        updated[existing] = true
    end
    updated[word] = blocked or nil
    local saved, err = self:_save(language, updated)
    if not saved then
        return nil, err
    end
    self.words[language] = updated
    return true
end

function BlockedWords:add(language, word)
    return self:_change(language, word, true)
end

function BlockedWords:remove(language, word)
    return self:_change(language, word, false)
end

return BlockedWords
