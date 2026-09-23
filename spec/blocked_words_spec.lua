local T = require("helper")
local it = T.it

local root = "/tmp/claude-1000/tapless-blocked-spec"

local function fresh()
    os.execute("rm -rf " .. root)
    return T.load("blocked_words"):new(root, function(path)
        os.execute("mkdir -p " .. path)
    end)
end

it("blocks and unblocks words for one language", function()
    local blocked = fresh()
    T.eq(blocked:contains("en", "bq"), false)
    T.truthy(blocked:add("en", "BQ"))
    T.eq(blocked:contains("en", "bq"), true)
    T.eq(blocked:contains("en", "Bq"), true, "any case")
    T.eq(blocked:contains("pl", "bq"), false, "other language")
    T.truthy(blocked:remove("en", "bq"))
    T.eq(blocked:contains("en", "bq"), false)
end)

it("keeps blocked words across restarts", function()
    local blocked = fresh()
    blocked:add("en", "sjw")
    blocked:add("en", "bq")
    local reloaded = T.load("blocked_words"):new(root)
    T.eq(table.concat(reloaded:list("en"), ","), "bq,sjw")
end)

it("ignores languages that are not dictionary ids", function()
    local blocked = fresh()
    T.eq(blocked:add("../x", "bq"), false)
    T.eq(blocked:contains("../x", "bq"), false)
end)
