local T = require("helper")
local it = T.it

local Replay = dofile(T.plugin_dir .. "/../tools/replay.lua")
local CleanSwipes = dofile(T.plugin_dir .. "/../tools/clean_swipes.lua")
local ShapeChannel = T.load("shape_channel")
local PathShape = T.load("path_shape")

local store = Replay.loadPlugin(T.plugin_dir).engine.dictionary_store
local LONG = string.rep("x", 12) -- letters crossed: enough to trigger

-- A clean swipe of word, its vertical movement scaled by squash around
-- the middle row (1 leaves it as it is).
local function swipe(word, squash)
    local keys = CleanSwipes.defaultKeys()
    local attempt = CleanSwipes.attempt(word, keys)
    local centers, middle = {}, nil
    for _, key in ipairs(keys) do
        centers[string.byte(key.key)] = { x = key.x + key.w / 2,
            y = key.y + key.h / 2, size = math.max(key.w, key.h) }
        if key.key == "a" then middle = key.y + key.h / 2 end
    end
    local points = {}
    for _, event in ipairs(attempt.events) do
        points[#points + 1] = { x = event.pos[1],
            y = middle + (event.pos[2] - middle) * (squash or 1) }
    end
    return points, centers
end

local function channel(blocked)
    return ShapeChannel:new(store, PathShape:new(), nil, blocked)
end

local function words(found)
    local out = {}
    for index, item in ipairs(found) do out[index] = item.entry.word end
    return out
end

local function position(list, word)
    for index, item in ipairs(list) do
        if item == word then return index end
    end
end

it("finds a long word by the shape of its swipe", function()
    local points, centers = swipe("important")
    local found = words(channel():candidates{ signature = LONG,
        points = points, key_centers = centers })
    local at = position(found, "important")
    T.truthy(at and at <= 3, table.concat(found, ","))
end)

it("does nothing for a swipe crossing few letters", function()
    local points, centers = swipe("important")
    T.eq(#channel():candidates{ signature = "imt", points = points,
        key_centers = centers }, 0)
end)

it("only offers words whose ends and length fit the swipe", function()
    local points, centers = swipe("important")
    local shapes = PathShape:new()
    local swiped = shapes:swipe(points)
    local ch = channel()
    local found = ch:candidates{ signature = LONG, points = points,
        key_centers = centers }
    T.truthy(#found > 0 and #found <= ch.KEEP)
    local function near(letter, point)
        local c = centers[string.byte(letter)]
        return math.sqrt((c.x - point.x) ^ 2 + (c.y - point.y) ^ 2)
            <= ch.REACH * c.size
    end
    for index, item in ipairs(found) do
        local signature = item.entry.gesture_signature
        T.truthy(near(signature:sub(1, 1), points[1]), signature)
        T.truthy(near(signature:sub(-1), points[#points]), signature)
        local ratio = swiped.length / shapes:ideal(signature, centers).length
        T.truthy(ratio >= ch.MIN_RATIO and ratio <= ch.MAX_RATIO, signature)
        if index > 1 then
            T.truthy(found[index - 1].rank <= item.rank, "sorted")
        end
    end
end)

it("never offers a blocked word", function()
    local points, centers = swipe("important")
    local blocked = { contains = function(_, _, word)
        return word == "important"
    end }
    local found = words(channel(blocked):candidates{ signature = LONG,
        points = points, key_centers = centers })
    T.eq(position(found, "important"), nil)
end)

it("finds a long word swiped flat", function()
    local points, centers = swipe("important", 0.4)
    local found = words(channel():candidates{ signature = LONG,
        points = points, key_centers = centers })
    T.truthy(position(found, "important"), table.concat(found, ","))
end)
