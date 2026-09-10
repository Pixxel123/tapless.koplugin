local Utf8Proc = require("ffi/utf8proc")

local TextCase = {}
TextCase.__index = TextCase

function TextCase:new(normalization)
    return setmetatable({
        normalization = assert(normalization),
    }, self)
end

function TextCase:uppercaseChar(char, language)
    if language == "tr" then
        if char == "i" then
            return "İ"
        elseif char == "ı" then
            return "I"
        end
    end
    return Utf8Proc.uppercase_dumb(char)
end

function TextCase:apply(word, mode, language)
    if not mode or type(word) ~= "string" or #word == 0 then
        return word
    end
    local chars = self.normalization:splitChars(word)
    if mode == "title" then
        chars[1] = self:uppercaseChar(chars[1], language)
    elseif mode == "upper" then
        for index, char in ipairs(chars) do
            chars[index] = self:uppercaseChar(char, language)
        end
    end
    return table.concat(chars)
end

return TextCase
