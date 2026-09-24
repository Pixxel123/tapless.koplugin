local T = require("helper")
local it = T.it

local FitWeights = dofile(T.plugin_dir .. "/../tools/fit_weights.lua")
local CleanSwipes = dofile(T.plugin_dir .. "/../tools/clean_swipes.lua")
local Replay = dofile(T.plugin_dir .. "/../tools/replay.lua")

-- Two candidates per swipe; the intended word is the first. It crossed
-- one letter fewer (spatial 1 against 0) but is ten times as common.
local function swipes(count)
    local list = {}
    for index = 1, count do
        list[index] = {
            target = 1,
            rows = {
                { features = { 1, -2 } },
                { features = { 0, -1 } },
            },
        }
    end
    return list
end

it("counts swipes that rank the intended word first", function()
    T.eq(FitWeights.topOne(swipes(3), { 3, 1 }), 0)
    T.eq(FitWeights.topOne(swipes(3), { 0.5, 1 }), 3)
end)

it("fits weights that rank the intended words first", function()
    local data = swipes(20)
    local start = { 3, 1 }
    local weights = FitWeights.fit(data, start)
    T.truthy(FitWeights.loss(data, weights, 0)
        < FitWeights.loss(data, start, 0), "loss went down")
    T.eq(FitWeights.topOne(data, weights), 20)
end)

it("reads fitted weights as the plugin's constants", function()
    local constants = FitWeights.constants({ 0.3, 1, 0.81, 2.5, 5.3 })
    T.truthy(math.abs(constants.SCORE_UNIT - 300) < 1e-9, "SCORE_UNIT")
    T.truthy(math.abs(constants.RARE_SHORT_COST - 2.7) < 1e-9,
        "RARE_SHORT_COST")
    T.truthy(math.abs(constants.REPEAT_BONUS - 2500) < 1e-9, "REPEAT_BONUS")
    T.truthy(math.abs(constants.RANK_WEIGHT - 5300) < 1e-9, "RANK_WEIGHT")
end)

it("describes a swipe's candidates by the features the ranking uses",
        function()
    local plugin = Replay.loadPlugin(T.plugin_dir)
    local swipe = FitWeights.candidateFeatures(plugin,
        CleanSwipes.attempt("water", CleanSwipes.defaultKeys()))
    T.truthy(swipe, "water is among its own swipe's candidates")
    T.eq(swipe.rows[swipe.target].word, "water")
    T.eq(#swipe.rows[1].features, #FitWeights.FEATURES)
    -- The current weights reproduce the engine's choice.
    local start = FitWeights.currentWeights(plugin.engine.scoring,
        plugin.engine.geometry_reranker)
    T.eq(FitWeights.topOne({ swipe }, start), 1)
end)
