local T = require("helper")
local it = T.it

local OneHanded = T.load("one_handed")

-- Kindle Paperwhite (12th gen): 1264 x 1680 px at 300 ppi, 107.02 mm wide.
local PORTRAIT = { w = 1264, h = 1680, dpi = 300 }
local LANDSCAPE = { w = 1680, h = 1264, dpi = 300 }
-- A 6-inch Kindle: 90.8 mm wide.
local SIX_INCH = { w = 758, h = 1024, dpi = 212 }
local SCREEN_MM = 1264 * 25.4 / 300

local RIGHT = { left = SCREEN_MM - 68, width = 68, height = 60 }
local LEFT = { left = 0, width = 68, height = 60 }

local function near(actual, expected, message)
    if type(actual) ~= "number" or math.abs(actual - expected) > 0.05 then
        error((message or "values differ") .. ": expected "
            .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function newSettings()
    local values = {}
    return {
        values = values,
        readSetting = function(_, name) return values[name] end,
        saveSetting = function(_, name, value) values[name] = value end,
    }
end

it("starts off, 68 mm wide against the right edge, at normal height",
        function()
    local state = OneHanded:new(newSettings()):state(PORTRAIT)
    T.eq(state.enabled, false, "enabled")
    T.eq(state.width, 68, "width")
    near(state.left, SCREEN_MM - 68, "left")
    T.eq(state.height, nil, "height")
end)

it("remembers portrait and landscape separately", function()
    local one_handed = OneHanded:new(newSettings())
    one_handed:toggle(PORTRAIT)
    T.eq(one_handed:state(PORTRAIT).enabled, true, "portrait")
    T.eq(one_handed:state(LANDSCAPE).enabled, false, "landscape")
end)

it("saves position and size in tenths of a millimetre", function()
    local settings = newSettings()
    OneHanded:new(settings):saveBlock(PORTRAIT,
        { left = 10.123, width = 70, height = 60.04 })
    local saved = settings.values.tapless_one_handed.portrait
    T.eq(saved.enabled, true, "enabled")
    T.eq(saved.left_mm, 10.1, "left")
    T.eq(saved.width_mm, 70, "width")
    T.eq(saved.height_mm, 60, "height")
end)

it("keeps the width between 64 and 92 mm", function()
    T.eq(OneHanded.fit({ width = 100 }, PORTRAIT).width, 92, "wide")
    T.eq(OneHanded.fit({ width = 40 }, PORTRAIT).width, 64, "narrow")
end)

it("leaves 12 mm beside the keys on a small screen", function()
    near(OneHanded.fit({ width = 92 }, SIX_INCH).width,
        758 * 25.4 / 212 - 12)
end)

it("keeps the height between 45 mm and 55% of the screen", function()
    near(OneHanded.fit({ width = 68, height = 75 }, LANDSCAPE).height,
        1264 * 25.4 / 300 * 0.55, "landscape cap")
    T.eq(OneHanded.fit({ width = 68, height = 30 }, PORTRAIT).height, 45,
        "short")
    T.eq(OneHanded.fit({ width = 68, height = 80 }, PORTRAIT).height, 75,
        "tall")
end)

it("pulls a saved position that no longer fits back on screen", function()
    local settings = newSettings()
    settings.values.tapless_one_handed = {
        portrait = { enabled = true, left_mm = 80, width_mm = 68 },
    }
    near(OneHanded:new(settings):state(PORTRAIT).left, SCREEN_MM - 68)
end)

it("falls back to the defaults for damaged saved values", function()
    local settings = newSettings()
    settings.values.tapless_one_handed = {
        portrait = { enabled = "yes", left_mm = "x", width_mm = {},
            height_mm = 0 / 0 },
    }
    local state = OneHanded:new(settings):state(PORTRAIT)
    T.eq(state.enabled, false, "enabled")
    T.eq(state.width, 68, "width")
    near(state.left, SCREEN_MM - 68, "left")
    T.eq(state.height, nil, "height")
end)

it("snaps the keys to an edge within 3 mm", function()
    T.eq(OneHanded.snap({ left = 2, width = 68 }, PORTRAIT).left, 0, "left")
    near(OneHanded.snap({ left = SCREEN_MM - 70, width = 68 }, PORTRAIT).left,
        SCREEN_MM - 68, "right")
    T.eq(OneHanded.snap({ left = 20, width = 68 }, PORTRAIT).left, 20,
        "middle")
end)

it("moves the keys along the bottom", function()
    local block = OneHanded.drag(LEFT, "move", 10, 5, PORTRAIT)
    T.eq(block.left, 10, "left")
    T.eq(block.width, 68, "width")
    T.eq(block.height, 60, "height")
end)

it("grows from a top corner, keeping the opposite edges", function()
    local block = OneHanded.drag(RIGHT, "tl", -5, -5, PORTRAIT)
    T.eq(block.width, 73, "width")
    near(block.left, SCREEN_MM - 73, "left")
    T.eq(block.height, 65, "height")
end)

it("changes only the width from a bottom corner", function()
    local block = OneHanded.drag(LEFT, "br", 30, -20, PORTRAIT)
    T.eq(block.width, 92, "width capped")
    T.eq(block.left, 0, "left")
    T.eq(block.height, 60, "height")
end)

it("keeps a narrowed block at least 64 mm wide", function()
    local block = OneHanded.drag(RIGHT, "bl", 10, 0, PORTRAIT)
    T.eq(block.width, 64, "width")
    near(block.left, SCREEN_MM - 64, "left")
end)

it("snaps a right corner to the right edge without moving the left",
        function()
    local start = { left = 20, width = 68, height = 60 }
    local block = OneHanded.drag(start, "tr", 17.02, 0, PORTRAIT)
    T.eq(block.left, 20, "left stays")
    near(block.width, 87.02, "width reaches the edge")
end)

it("snaps a left corner to the left edge without moving the right",
        function()
    local start = { left = 22, width = 64, height = 60 }
    local block = OneHanded.drag(start, "tl", -20, 0, PORTRAIT)
    T.eq(block.left, 0, "left reaches the edge")
    near(block.width, 86, "right stays")
end)

it("keeps the right edge put when a left snap's width needs capping",
        function()
    local start = { left = 5, width = 89, height = 60 }
    local block = OneHanded.drag(start, "tl", -3, 0, PORTRAIT)
    T.eq(block.width, 92, "width capped")
    near(block.left + block.width, 94, "right stays, left does not reach 0")
end)

it("resets to 68 mm wide with a nil height on the nearer edge", function()
    local from_left = OneHanded.reset(
        { left = 5, width = 80, height = 50 }, PORTRAIT)
    T.eq(from_left.left, 0, "left edge")
    T.eq(from_left.width, 68, "width")
    T.eq(from_left.height, nil, "height")
    local from_right = OneHanded.reset(
        { left = 30, width = 70, height = 50 }, PORTRAIT)
    near(from_right.left, SCREEN_MM - 68, "right edge")
end)

it("keeps a nil height across a move", function()
    local start = { left = 20, width = 68, height = nil }
    local block = OneHanded.drag(start, "move", 10, 5, PORTRAIT, 42.8)
    T.eq(block.height, nil, "height")
end)

it("keeps a nil height across a bottom-corner drag", function()
    local start = { left = 20, width = 68, height = nil }
    local block = OneHanded.drag(start, "br", 10, -5, PORTRAIT, 42.8)
    T.eq(block.height, nil, "height")
end)

it("makes a height from normal_height on a top-corner drag", function()
    local start = { left = 20, width = 68, height = nil }
    local block = OneHanded.drag(start, "tl", 0, -5, PORTRAIT, 42.8)
    near(block.height, 47.8, "height")
end)

it("points the arrow at the far edge", function()
    T.eq(OneHanded.target(RIGHT, PORTRAIT), "left", "from the right")
    T.eq(OneHanded.target(LEFT, PORTRAIT), "right", "from the left")
end)

it("moves the saved keys to the edge the arrow points at", function()
    local one_handed = OneHanded:new(newSettings())
    one_handed:setEnabled(PORTRAIT, true)
    T.eq(one_handed:moveToTarget(PORTRAIT).left, 0, "to the left")
    near(one_handed:moveToTarget(PORTRAIT).left, SCREEN_MM - 68, "and back")
end)

it("lays out the keys frame and puts the handle on the roomier side",
        function()
    local right = OneHanded.layout(RIGHT, PORTRAIT, 4)
    T.eq(right.frame_x, 461, "frame x")
    T.eq(right.frame_w, 803, "frame width")
    T.eq(right.inner_w, 795, "inner width")
    T.eq(right.after, 0, "room after")
    T.eq(right.handle_side, "left", "handle side")
    local left = OneHanded.layout(LEFT, PORTRAIT, 4)
    T.eq(left.frame_x, 0, "left frame x")
    T.eq(left.after, 461, "left room after")
    T.eq(left.handle_side, "right", "left handle side")
    local middle = OneHanded.layout({ left = 20, width = 68 }, PORTRAIT, 4)
    T.eq(middle.handle_side, "left", "more room on the left")
end)

it("hints one-handed mode with ◨", function()
    T.eq(OneHanded.HINT, "◨")
end)

it("converts between millimetres and pixels", function()
    T.eq(OneHanded.toPx(25.4, PORTRAIT), 300, "to pixels")
    near(OneHanded.toMM(300, PORTRAIT), 25.4, "to millimetres")
end)
