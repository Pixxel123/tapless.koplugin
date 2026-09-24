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
