local T = require("helper")
local it = T.it

local ROOT = "/tmp/claude-1000/tapless-personal-spec"

-- The dictionary is given its folder, so these only need to load.
package.loaded["datastorage"] = package.loaded["datastorage"]
    or { getDataDir = function() return ROOT end }
package.loaded["util"] = package.loaded["util"] or {}
package.loaded["util"].makePath = function(path)
    os.execute("mkdir -p " .. path)
end

-- Normalization that also accepts whole words, as the real one does.
local normalization = setmetatable({
    normalizeText = function(_, text) return text:lower() end,
}, { __index = T.normalization })

local function newDictionary()
    return T.load("personal_dictionary"):new(normalization,
        T.load("dictionary_index"), ROOT)
end

it("adds, keeps and removes personal words", function()
    os.execute("rm -rf " .. ROOT)
    local dictionary = newDictionary()
    T.truthy(dictionary:add("en", "Tapless"))
    T.truthy(dictionary:add("en", "kobo"))
    local reloaded = newDictionary()
    T.eq(table.concat(reloaded:list("en"), ","), "kobo,tapless")
    T.truthy(reloaded:remove("en", "kobo"))
    T.eq(table.concat(newDictionary():list("en"), ","), "tapless")
end)
