local T = require("helper")
local it = T.it

local UsageModel = T.load("usage_model")

local function newSettings(values)
    local settings = { values = values or {}, saved = 0 }
    function settings:readSetting(key, default)
        if self.values[key] == nil then return default end
        return self.values[key]
    end
    function settings:saveSetting(key, value)
        self.values[key] = value
        self.saved = self.saved + 1
    end
    return settings
end

local function newModel(values)
    local settings = newSettings(values)
    return UsageModel:new(settings, "usage"), settings
end

it("counts a word from zero, capped", function()
    local model = newModel()
    T.eq(model:uses("water"), 0)
    model:learn("water", 2)
    model:learn("water")
    T.eq(model:uses("water"), 3)
    model:learn("water", 1000)
    T.eq(model:uses("water"), 255)
end)

it("ignores an empty or missing word", function()
    local model, settings = newModel()
    model:learn(nil, 1)
    model:learn("", 1)
    model:save()
    T.eq(settings.saved, 0)
end)

it("drops the least used word when it holds too many", function()
    local model = newModel()
    model.MAX_WORDS = 3
    model:learn("a1", 5)
    model:learn("a2", 1)
    model:learn("a3", 3)
    model:learn("a4", 1)
    T.eq(model:uses("a4"), 1, "the new word stays")
    T.eq(model:uses("a2"), 0, "the least used word goes")
    T.eq(model:uses("a1"), 5)
    T.eq(model:uses("a3"), 3)
end)

it("counts the words already saved when deciding it holds too many", function()
    local model = newModel({ usage = { a1 = 4, a2 = 1, a3 = 2 } })
    model.MAX_WORDS = 3
    model:learn("a4", 1)
    T.eq(model:uses("a2"), 0, "the least used saved word goes")
    T.eq(model:uses("a4"), 1)
end)

it("learns a kept word once", function()
    local model = newModel()
    local pending = { word = "water" }
    model:commit(pending)
    model:commit(pending)
    T.eq(model:uses("water"), 1)
    T.truthy(pending.usage_committed)
    model:commit(nil)
end)

it("does not count a word a pick has already counted", function()
    local model = newModel()
    model:commit({ word = "water", usage_committed = true })
    T.eq(model:uses("water"), 0)
end)

it("saves only after a change", function()
    local model, settings = newModel()
    model:save()
    T.eq(settings.saved, 0)
    model:learn("water")
    model:save()
    model:save()
    T.eq(settings.saved, 1)
    T.eq(settings.values.usage.water, 1)
end)

it("starts empty when the saved value is not a table", function()
    local model = newModel({ usage = "broken" })
    T.eq(model:uses("water"), 0)
    model:learn("water")
    T.eq(model:uses("water"), 1)
end)

it("keeps a paused model from learning through commit", function()
    local model = newModel()
    model.learn = function() end
    model:commit({ word = "water" })
    T.eq(model:uses("water"), 0)
end)
