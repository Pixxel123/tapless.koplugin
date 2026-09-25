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

it("gives long swipes' merged candidates their missing letters", function()
    local plugin = Replay.loadPlugin(T.plugin_dir)
    local keys = CleanSwipes.defaultKeys()
    local attempt = CleanSwipes.attempt("important", keys)
    local swipe = FitWeights.shapeFeatures(plugin, attempt)
    T.truthy(swipe, "the channel ran and important was a candidate")
    T.eq(swipe.rows[swipe.target].word, "important")
    T.eq(#swipe.rows[1].features, 6)
    T.eq(swipe.rows[swipe.target].features[6], 0, "nothing missing")
    -- The starting weights reproduce the engine's choice.
    local start = FitWeights.shapeWeights(plugin.engine.scoring,
        plugin.engine.shape_channel)
    T.eq(FitWeights.topOne({ swipe }, start), 1)
end)

-- A stand-in for the scoring whose plain alignment scores plain, whose
-- costed alignment leaves out costed_missing letters, and which records
-- the missing cost of each call.
local function stubScoring(plain, costed_missing)
    local stub = { costs = {} }
    function stub:dynamicMatchScore(_, _, _, _, _, _, _, _, _, cost)
        self.costs[#self.costs + 1] = cost or false
        if cost then
            return 12, false, {}, costed_missing
        end
        return plain, false, {}
    end
    return stub
end

it("counts missing letters from the alignment the score used", function()
    local metadata = { allow_near = false }
    local function missing(scoring)
        return FitWeights.missingLetters(scoring, "abcd", { "a", "d" }, {},
            {}, metadata, nil, 2)
    end
    -- The plain alignment found a path: it is the one ranked, so nothing
    -- is missing, whatever the costed one would have left out.
    local found = stubScoring(5, 1)
    T.eq(missing(found), 0)
    T.eq(#found.costs, 1)
    T.eq(found.costs[1], false)
    -- It hit the wall: the costed alignment is ranked, and counts.
    local walled = stubScoring(1080, 2)
    T.eq(missing(walled), 2)
    T.eq(walled.costs[2], 2)
    -- A costed alignment that also fails leaves nothing counted.
    T.eq(missing(stubScoring(1080, nil)), 0)
end)
