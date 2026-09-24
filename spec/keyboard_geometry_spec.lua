local T = require("helper")
local it = T.it

local KeyboardGeometry = T.load("keyboard_geometry")

-- KOReader's Geom:contains (frontend/ui/geometry.lua) reads the other
-- rectangle's w and h, so a bare point without them raises an error.
local function strictContains(self, geom)
    return self.x <= geom.x and self.y <= geom.y
        and self.x + self.w >= geom.x + geom.w
        and self.y + self.h >= geom.y + geom.h
end

-- Two 100px keys side by side: q from 0 to 100, w from 100 to 200.
local function newLayout()
    local row = {}
    for index, letter in ipairs({ "q", "w" }) do
        row[index] = {
            key = letter,
            dimen = {
                x = (index - 1) * 100, y = 0, w = 100, h = 100,
                contains = strictContains,
            },
        }
    end
    return { row }
end

it("finds the key under a trace point, which has no size", function()
    local geometry = KeyboardGeometry:new(T.normalization)
    T.eq(geometry:keyAt(newLayout(), { x = 150, y = 50, time = 1 }), "w")
end)

it("takes a point on a shared edge as the first key, as KOReader does",
        function()
    local geometry = KeyboardGeometry:new(T.normalization)
    T.eq(geometry:keyAt(newLayout(), { x = 100, y = 50 }), "q")
end)

-- A number row of 1 and 2 above the letters q and w, each 100px square.
local function newNumberRowLayout()
    local function rowOf(keys, y)
        local row = {}
        for index, key in ipairs(keys) do
            row[index] = {
                key = key,
                dimen = {
                    x = (index - 1) * 100, y = y, w = 100, h = 100,
                    contains = strictContains,
                },
            }
        end
        return row
    end
    return { rowOf({ "1", "2" }, 0), rowOf({ "q", "w" }, 100) }
end

it("starts a swipe that lands on a number-row key on the letter below",
        function()
    local geometry = KeyboardGeometry:new(T.normalization)
    local layout = newNumberRowLayout()
    local letter, key = geometry:startKeyAt(layout, { x = 150, y = 90 })
    T.eq(letter, "w")
    T.eq(key.key, "w")
    letter, key = geometry:startKeyAt(layout, { x = 30, y = 5 })
    T.eq(letter, "q", "even high in the number row")
end)

it("counts the shift layer's number row, whose keys carry the digit as alternate",
        function()
    local geometry = KeyboardGeometry:new(T.normalization)
    local layout = newNumberRowLayout()
    layout[1][2].key = "@"
    layout[1][2].alt_label = "2"
    local letter, key = geometry:startKeyAt(layout, { x = 150, y = 90 })
    T.eq(letter, "w")
    T.eq(key.key, "w")
    layout[1][2].alt_label = "!"
    T.eq(geometry:startKeyAt(layout, { x = 150, y = 90 }), nil,
        "a symbol key with no digit is not a number key")
end)

it("still takes a number-row key as no letter when only asked what is there",
        function()
    local geometry = KeyboardGeometry:new(T.normalization)
    local letter, key = geometry:keyAt(newNumberRowLayout(),
        { x = 150, y = 90 })
    T.eq(letter, nil)
    T.eq(key.key, "2")
end)

it("starts a swipe on a letter key where it landed", function()
    local geometry = KeyboardGeometry:new(T.normalization)
    local letter, key = geometry:startKeyAt(newNumberRowLayout(),
        { x = 150, y = 150 })
    T.eq(letter, "w")
    T.eq(key.key, "w")
end)

it("leaves a number-row key with no letter below it as a digit key", function()
    local geometry = KeyboardGeometry:new(T.normalization)
    local layout = newNumberRowLayout()
    table.remove(layout[2], 2)
    local letter, key = geometry:startKeyAt(layout, { x = 150, y = 90 })
    T.eq(letter, nil)
    T.eq(key.key, "2")
    layout[2] = nil
    letter, key = geometry:startKeyAt(layout, { x = 50, y = 90 })
    T.eq(letter, nil)
    T.eq(key.key, "1")
end)

it("does not move a start off a key that is not a number", function()
    local geometry = KeyboardGeometry:new(T.normalization)
    local layout = newNumberRowLayout()
    layout[1][2].key = "Shift"
    local letter, key = geometry:startKeyAt(layout, { x = 150, y = 90 })
    T.eq(letter, nil)
    T.eq(key.key, "Shift")
end)

it("finds no start for a point outside every key", function()
    local geometry = KeyboardGeometry:new(T.normalization)
    T.eq(geometry:startKeyAt(newNumberRowLayout(), { x = 500, y = 500 }), nil)
    T.eq(geometry:startKeyAt(nil, { x = 50, y = 50 }), nil)
    T.eq(geometry:startKeyAt(newNumberRowLayout(), nil), nil)
end)
