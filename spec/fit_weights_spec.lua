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
    local constants = FitWeights.constants({ 0.3, 1, 0.81, 2.5, 5.3, 0.4 })
    T.truthy(math.abs(constants.SCORE_UNIT - 300) < 1e-9, "SCORE_UNIT")
    T.truthy(math.abs(constants.RARE_SHORT_COST - 2.7) < 1e-9,
        "RARE_SHORT_COST")
    T.truthy(math.abs(constants.REPEAT_BONUS - 2500) < 1e-9, "REPEAT_BONUS")
    T.truthy(math.abs(constants.RANK_WEIGHT - 5300) < 1e-9, "RANK_WEIGHT")
    T.truthy(math.abs(constants.NEAR_RANK_COST - 400) < 1e-9,
        "NEAR_RANK_COST")
end)

it("counts letters borrowed from neighbouring keys", function()
    T.eq(FitWeights.borrowedLetters("wine", { "w", "u", "n", "e" },
        { 1, 2, 3, 4 }), 1)
    T.eq(FitWeights.borrowedLetters("wyne", { "w", "y", "n", "e" },
        { 1, 2, 3, 4 }), 0)
    -- A different last letter is an endpoint mismatch, not a borrowing.
    T.eq(FitWeights.borrowedLetters("wind", { "w", "i", "n", "e" },
        { 1, 2, 3, 4 }), 0)
end)

it("gives smaller standard errors with more swipes", function()
    -- Half the swipes intend each candidate, so the weights stay finite.
    local function mixed(count)
        local list = {}
        for index = 1, count do
            list[index] = {
                target = index % 2 + 1,
                rows = {
                    { features = { 1, -2 } },
                    { features = { 0, -1.5 } },
                },
            }
        end
        return list
    end
    local few, many = mixed(10), mixed(40)
    local few_se = FitWeights.standardErrors(few,
        FitWeights.fit(few, { 1, 1 }))
    local many_se = FitWeights.standardErrors(many,
        FitWeights.fit(many, { 1, 1 }))
    for k = 1, 2 do
        T.truthy(few_se[k] > 0 and few_se[k] < math.huge, "finite " .. k)
        T.truthy(many_se[k] < few_se[k], "shrinks " .. k)
    end
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
