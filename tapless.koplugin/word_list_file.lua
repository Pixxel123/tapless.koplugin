-- The per-language word list files kept under the KOReader data folder
-- (personal words, blocked words): language ids and saving.
local WordListFile = {}

function WordListFile.validLanguage(language)
    return type(language) == "string"
        and language:match("^[a-z][a-z0-9-]*$") ~= nil
end

-- Writes words (a set) sorted under a header line, replacing the file only
-- once it is complete. make_folder() creates the folder first. Returns
-- true, or nil and an error naming what.
function WordListFile.save(path, header, words, make_folder, what)
    make_folder()
    local temporary = path .. ".tmp"
    local file = io.open(temporary, "wb")
    if not file then
        return nil, "Cannot write " .. what
    end
    file:write(header, "\n")
    local sorted = {}
    for word in pairs(words) do
        sorted[#sorted + 1] = word
    end
    table.sort(sorted)
    for _, word in ipairs(sorted) do
        file:write(word, "\n")
    end
    file:close()
    if not os.rename(temporary, path) then
        os.remove(temporary)
        return nil, "Cannot replace " .. what
    end
    return true
end

return WordListFile
