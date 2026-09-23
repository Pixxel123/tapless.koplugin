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
local function recognize(words, signature, start, intents)
    local layout = newLayout()
    local geometry = T.load("keyboard_geometry"):new(T.normalization)
    local scoring = T.load("scoring"):new(T.normalization)
    local engine = T.load("recognition_engine"):new(newStore(words), scoring,
        T.load("geometry_reranker"):new())
    local points, observations = { start }, {}
    for index = 1, #signature do
        if index > 1 then
            points[index] = center(layout, signature:sub(index, index))
        end
        observations[index] = { intent = intents and intents[index] or 1 }
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
