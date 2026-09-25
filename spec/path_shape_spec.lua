local T = require("helper")
local it = T.it

local PathShape = T.load("path_shape")

local function centers(dx)
    dx = dx or 0
    local out = {}
    for index, letter in ipairs({ "a", "b", "c", "d" }) do
        out[string.byte(letter)] = { x = index * 100 + dx, y = 50, size = 100 }
    end
    return out
end

it("resamples a path to evenly spaced points", function()
    local samples, length = PathShape.resample({
        { x = 0, y = 0 }, { x = 100, y = 0 } }, 5)
    T.eq(length, 100)
    T.eq(#samples, 10)
    T.eq(samples[1], 0)
    T.eq(samples[3], 25)
    T.eq(samples[9], 100)
end)

it("keeps a word's ideal path for the same key positions", function()
    local shape = PathShape:new()
    local first = shape:ideal("abd", centers())
    T.truthy(first)
    T.truthy(rawequal(shape:ideal("abd", centers()), first),
        "same positions in a new table")
    T.truthy(not rawequal(shape:ideal("abd", centers(5)), first),
        "positions moved")
end)

it("drops the older half of the kept paths", function()
    local shape = PathShape:new()
    shape.CACHE_WORDS = 4
    local kept = shape:ideal("ab", centers())
    shape:ideal("ac", centers())
    T.truthy(rawequal(shape:ideal("ab", centers()), kept), "still kept")
    shape:ideal("ad", centers())
    shape:ideal("bc", centers())
    shape:ideal("bd", centers())
    T.truthy(not rawequal(shape:ideal("ab", centers()), kept), "dropped")
end)

it("scores a swipe along a word's own path as a perfect match", function()
    local shape = PathShape:new()
    local c = centers()
    local points = {}
    for _, letter in ipairs({ "a", "b", "d" }) do
        local center = c[string.byte(letter)]
        points[#points + 1] = { x = center.x, y = center.y }
    end
    local swipe = shape:swipe(points)
    T.eq(shape:score(swipe, shape:ideal("abd", c)), 0)
    T.truthy(shape:score(swipe, shape:ideal("ad", c)) >= 0)
end)

it("has no ideal path for a word with a letter off the keyboard", function()
    T.eq(PathShape:new():ideal("az", centers()), nil)
end)
