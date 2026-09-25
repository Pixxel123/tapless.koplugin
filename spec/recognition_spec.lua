local T = require("helper")
local it = T.it

-- A QWERTY keyboard with 100px keys; each row is shifted half a key.
local ROWS = { "qwertyuiop", "asdfghjkl", "zxcvbnm" }

local function newLayout()
    local layout = {}
    for row_index, letters in ipairs(ROWS) do
        local row = {}
        for index = 1, #letters do
            row[index] = {
                key = letters:sub(index, index),
                dimen = {
                    x = (row_index - 1) * 50 + (index - 1) * 100,
                    y = (row_index - 1) * 100,
                    w = 100,
                    h = 100,
                },
            }
        end
        layout[row_index] = row
    end
    return layout
end

-- words: { { word, freq }, ... }, bucketed by first and last letter.
local function newStore(words)
    local buckets = {}
    for _, item in ipairs(words) do
        local word = item[1]
        local key = word:sub(1, 1) .. word:sub(-1)
        local bucket = buckets[key] or { by_gesture_length = {} }
        buckets[key] = bucket
        local by_length = bucket.by_gesture_length
        by_length[#word] = by_length[#word] or {}
        table.insert(by_length[#word], {
            word = word,
            signature = word,
            gesture_signature = word,
            freq = item[2],
        })
    end
    return {
        open = function()
            return { descriptor = {} }
        end,
        loadBucket = function(_, first, last)
            return buckets[first .. last]
        end,
        loadPopularWords = function()
            return {}
        end,
    }
end

local function center(layout, letter)
    for _, row in ipairs(layout) do
        for _, key in ipairs(row) do
            if key.key == letter then
                return {
                    x = key.dimen.x + key.dimen.w / 2,
                    y = key.dimen.y + key.dimen.h / 2,
                }
            end
        end
    end
end

-- signature: letters the finger crossed. start: where the finger landed.
-- intents: how deliberately each letter was crossed (turns score high).
-- turns: how far the path turned on each letter's key, in radians.
-- word_uses(word) says how often the user has kept a word; tune(scoring)
-- may pin the constants the test depends on.
local function recognize(words, signature, start, intents, turns, blocked,
        word_uses, tune)
    local layout = newLayout()
    local geometry = T.load("keyboard_geometry"):new(T.normalization)
    local scoring = T.load("scoring"):new(T.normalization)
    if tune then
        tune(scoring)
    end
    local engine = T.load("recognition_engine"):new(newStore(words), scoring,
        T.load("geometry_reranker"):new(T.load("path_shape"):new()), nil,
        blocked)
    local points, observations = { start }, {}
    for index = 1, #signature do
        if index > 1 then
            points[index] = center(layout, signature:sub(index, index))
        end
        observations[index] = {
            intent = intents and intents[index] or 1,
            signed_turn = turns and turns[index] or 0,
        }
    end
    local trace_info = {
        letter_points = points,
        points = points,
        endpoint_pos = points[#points],
        observations = observations,
    }
    return engine:pickCandidates{
        signature = signature,
        limit = 4,
        trace_info = trace_info,
        key_centers = geometry:keyCenters(layout),
        start_letters = function(first)
            return geometry:startLetters(layout, start, first)
        end,
        endpoint_letters = function(last)
            return geometry:endpointLetters(layout, trace_info.endpoint_pos,
                last)
        end,
        word_uses = word_uses,
    }
end

local function words(results)
    local list = {}
    for index, result in ipairs(results) do
        list[index] = result.word
    end
    return table.concat(list, ",")
end

it("finds a short word when the swipe starts on a neighbouring key",
        function()
    -- Aiming for w, the finger lands on the right edge of q.
    local results = recognize({ { "was", 6000 } }, "qas", { x = 95, y = 60 })
    T.eq(words(results), "was")
end)

it("finds a long word when the swipe starts on a neighbouring key",
        function()
    local results = recognize({ { "water", 5000 } }, "qasdftrer",
        { x = 95, y = 60 },
        { 0.9, 0.9, 0.3, 0.3, 0.3, 0.9, 0.3, 0.9, 0.9 })
    T.eq(words(results), "water")
end)

it("prefers the key the swipe started on over its neighbour", function()
    -- The finger lands on the left edge of r; "eat" is more common.
    local results = recognize({ { "rat", 5000 }, { "eat", 6000 } },
        "redsasdft", { x = 310, y = 55 },
        { 0.9, 0.3, 0.3, 0.3, 0.9, 0.3, 0.3, 0.3, 0.9 })
    T.eq(words(results), "rat,eat")
end)

it("ignores neighbouring keys when the swipe starts well inside a key",
        function()
    -- The finger lands in the middle of q.
    local results = recognize({ { "was", 6000 } }, "qas", { x = 50, y = 50 })
    T.eq(words(results), "")
end)

-- A path that turns on u, next to i, on its way to n: "wertyujnbvfde".
local NEAR_TRACE = "wertyujnbvfde"
local NEAR_INTENTS = { 0.9, 0.3, 0.3, 0.3, 0.3, 0.9, 0.3, 0.9, 0.3, 0.3,
    0.3, 0.3, 0.9 }
local NEAR_TURNS = { 0, 0, 0, 0, 0, 1.2, 1.2, 1.2, 0, 0, 0, 0, 0 }

it("finds a word when the path turns next to one of its letters",
        function()
    local results = recognize({ { "wine", 6000 } }, NEAR_TRACE,
        { x = 150, y = 50 }, NEAR_INTENTS,
        NEAR_TURNS)
    T.eq(words(results), "wine")
end)

it("prefers a word whose letters the path crossed when as common",
        function()
    local results = recognize({ { "wyne", 5000 }, { "wine", 5000 } },
        NEAR_TRACE, { x = 150, y = 50 }, NEAR_INTENTS,
        NEAR_TURNS)
    T.eq(words(results), "wyne,wine")
end)

it("allows at most two letters from neighbouring keys", function()
    -- i, h and m are next to u, j and n, where the path turned, but none
    -- were crossed.
    local results = recognize({ { "wihme", 6000 } }, NEAR_TRACE,
        { x = 150, y = 50 }, NEAR_INTENTS,
        NEAR_TURNS)
    T.eq(words(results), "")
end)

it("does not borrow a letter from a key the path went straight through",
        function()
    local results = recognize({ { "wine", 6000 } }, NEAR_TRACE,
        { x = 150, y = 50 }, NEAR_INTENTS)
    T.eq(words(results), "")
end)

it("ranks rare short words below words that fit as well", function()
    local scoring = T.load("scoring"):new(T.normalization)
    local function ranked(signature, freq)
        local _, score = scoring:finishEntryScore("bvcq",
            { gesture_signature = signature, freq = freq }, 2, {}, nil, 0)
        return score
    end
    local below = scoring.RARE_SHORT_FREQ - 100
    local above = scoring.RARE_SHORT_FREQ + 100
    local short = ("bcqxzv"):sub(1, scoring.RARE_SHORT_LENGTH)
    local long = ("bvcqxzv"):sub(1, scoring.RARE_SHORT_LENGTH + 1)
    -- A rare short word pays extra; a rare longer word does not.
    T.truthy(math.abs((ranked(short, below) - ranked(short, above))
        - (200 + scoring.RARE_SHORT_COST * scoring.SCORE_UNIT)) < 1e-6,
        "rare short cost applied exactly")
    T.eq(ranked(long, below) - ranked(long, above), 200)
end)

-- Constants the usage specs depend on, pinned on the instance so retuning
-- the defaults leaves them alone.
local function pinUsage(scoring)
    scoring.USAGE_UNIT = 500
    scoring.USAGE_CAP = 1500
    scoring.USAGE_CEILING = 6000
    scoring.KNOWN_USES = 3
    return scoring
end

it("gives a word nothing for one keep and a bonus per doubling after",
        function()
    local scoring = pinUsage(T.load("scoring"):new(T.normalization))
    T.eq(scoring:usageBonus(4000, nil), 0)
    T.eq(scoring:usageBonus(4000, 0), 0)
    T.eq(scoring:usageBonus(4000, 1), 0, "one keep may be a mistake")
    T.eq(scoring:usageBonus(4000, 2), 500)
    T.eq(scoring:usageBonus(4000, 4), 1000)
    T.eq(scoring:usageBonus(1000, 8), 1500, "capped")
    T.eq(scoring:usageBonus(1000, 255), 1500, "capped")
end)

it("never lifts a word past the frequency ceiling", function()
    local scoring = pinUsage(T.load("scoring"):new(T.normalization))
    T.eq(scoring:usageBonus(5800, 8), 200, "only the gap to the ceiling")
    T.eq(scoring:usageBonus(6000, 8), 0)
    T.eq(scoring:usageBonus(7500, 255), 0, "common words gain nothing")
    T.eq(scoring:usageBonus(nil, 2), 500, "a word with no frequency")
end)

it("takes the usage bonus off a word's ranked score", function()
    local scoring = pinUsage(T.load("scoring"):new(T.normalization))
    local function ranked(uses)
        local _, score = scoring:finishEntryScore("bvcqx",
            { gesture_signature = "bvcqx", freq = 4000 }, 2, {}, nil, 0, uses)
        return score
    end
    T.eq(ranked(0) - ranked(1), 0)
    T.eq(ranked(0) - ranked(2), 500)
    T.eq(ranked(0) - ranked(4), 1000)
    T.eq(ranked(nil), ranked(0), "no count is no uses")
end)

it("stops charging a word kept often enough as a rare short fragment",
        function()
    local scoring = pinUsage(T.load("scoring"):new(T.normalization))
    local short = ("bcqxzv"):sub(1, scoring.RARE_SHORT_LENGTH)
    local freq = scoring.RARE_SHORT_FREQ - 100
    local function ranked(uses)
        local _, score = scoring:finishEntryScore(short,
            { gesture_signature = short, freq = freq }, 2, {}, nil, 0, uses)
        return score
    end
    local cost = scoring.RARE_SHORT_COST * scoring.SCORE_UNIT
    T.truthy(math.abs(ranked(0) - ranked(1)) < 1e-6,
        "one keep still pays the cost")
    T.truthy(math.abs((ranked(0) - ranked(2))
        - scoring:usageBonus(freq, 2)) < 1e-6,
        "two keeps earn the bonus but still pay the cost")
    T.truthy(math.abs((ranked(0) - ranked(3))
        - (cost + scoring:usageBonus(freq, 3))) < 1e-6,
        "enough keeps drop the cost and earn the bonus")
end)

it("puts a word the user keeps ahead of a slightly better fit", function()
    local candidates = { { "wyne", 5000 }, { "wine", 5000 } }
    local args = { NEAR_TRACE, { x = 150, y = 50 }, NEAR_INTENTS, NEAR_TURNS }
    local function order(word_uses)
        return words(recognize(candidates, args[1], args[2], args[3],
            args[4], nil, word_uses, function(scoring)
                pinUsage(scoring)
                -- Enough to outweigh what tells the two spellings apart.
                scoring.USAGE_UNIT = 100000
                scoring.USAGE_CAP = 100000
                scoring.USAGE_CEILING = 100000
            end))
    end
    T.eq(order(nil), "wyne,wine")
    T.eq(order(function() return 0 end), "wyne,wine")
    T.eq(order(function(word) return word == "wine" and 2 or 0 end),
        "wine,wyne")
end)

it("counts doubled letters when deciding a word is short", function()
    local scoring = T.load("scoring"):new(T.normalization)
    -- A doubled first letter makes the word one letter longer than the
    -- gesture signature, and so one longer than the short limit.
    local gesture = ("mortv"):sub(1, scoring.RARE_SHORT_LENGTH)
    local word = gesture:sub(1, 1) .. gesture
    local function ranked(freq)
        local _, score = scoring:finishEntryScore(gesture, {
            signature = word, gesture_signature = gesture, freq = freq,
        }, 2, {}, nil, 0)
        return score
    end
    local below = scoring.RARE_SHORT_FREQ - 100
    local above = scoring.RARE_SHORT_FREQ + 100
    T.eq(ranked(below) - ranked(above), 200, "a doubled letter still counts")
end)

it("limits letters from neighbouring keys in the final alignment too",
        function()
    local layout = newLayout()
    local geometry = T.load("keyboard_geometry"):new(T.normalization)
    local scoring = T.load("scoring"):new(T.normalization)
    local key_centers = geometry:keyCenters(layout)
    local chars = scoring:buildNextPositions(NEAR_TRACE)
    local points, observations = {}, {}
    for index = 1, #NEAR_TRACE do
        points[index] = center(layout, NEAR_TRACE:sub(index, index))
        observations[index] = {
            intent = NEAR_INTENTS[index],
            signed_turn = NEAR_TURNS[index],
        }
    end
    local near = scoring:buildNearPositions(chars, key_centers, observations)
    -- i, h and m would all have to come from neighbouring keys.
    local score = scoring:dynamicMatchScore("wihme", chars, false, points,
        points[#points], key_centers, observations, false, near)
    T.truthy(score >= 1000, "score " .. score)
    -- Two are allowed.
    score = scoring:dynamicMatchScore("wihne", chars, false, points,
        points[#points], key_centers, observations, false, near)
    T.truthy(score < 1000, "score " .. score)
end)

it("never suggests a blocked word", function()
    local words = { { "was", 6000 }, { "wqs", 3000 } }
    T.eq(recognize(words, "wqas", { x = 150, y = 50 })[1].word, "was")
    local blocked = {
        contains = function(_, language, word)
            return language == "en" and word == "was"
        end,
    }
    local results = recognize(words, "wqas", { x = 150, y = 50 }, nil, nil,
        blocked)
    T.eq(results[1].word, "wqs")
    for _, result in ipairs(results) do
        T.truthy(result.word ~= "was", "blocked word suggested")
    end
end)

local function rowOf(words, limit)
    local engine = T.load("recognition_engine")
    local candidates = {}
    for index, item in ipairs(words) do
        candidates[index] = { word = item[1], gesture_signature = item[2] }
    end
    local list = {}
    for index, candidate in ipairs(engine.fillRow(engine, candidates,
            limit)) do
        list[index] = candidate.word
    end
    return table.concat(list, ",")
end

it("leaves spellings that only repeat letters out of the row", function()
    T.eq(rowOf({ { "to", "to" }, { "too", "to" }, { "tooo", "to" },
        { "top", "top" }, { "tip", "tip" } }, 4), "to,too,top,tip")
    T.eq(rowOf({ { "we", "we" }, { "wwe", "we" }, { "wee", "we" },
        { "west", "west" } }, 4), "we,wwe,west")
end)

it("keeps a word in the row when every candidate repeats a letter",
        function()
    T.eq(rowOf({ { "zzz", "z" }, { "zzzz", "z" } }, 4), "zzz,zzzz")
end)
