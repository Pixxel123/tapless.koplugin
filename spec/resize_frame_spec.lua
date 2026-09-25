local T = require("helper")
local it = T.it

local ResizeFrame = T.load("resize_frame")

local Plain = { new = function(_, options) return options end }

local function newFrame(scheduled)
    return ResizeFrame:new{
        ui_manager = { scheduleIn = function(_, delay, fn)
            table.insert(scheduled, { delay = delay, fn = fn })
        end },
        input_container = Plain,
        overlap_group = Plain,
        vertical_group = Plain,
        vertical_span = Plain,
        horizontal_span = Plain,
        gesture_range = T.gesture_range,
        blitbuffer = { COLOR_BLACK = "black" },
        panel_button = { create = function(_, options) return options end },
        screen = { getDPI = function() return 300 end },
        icon_dir = "/icons",
    }
end

local RECT = { x = 400, y = 1000, w = 800, h = 600 }
local BUTTONS = {
    reset = { x = 700, y = 1150, w = 200, h = 90 },
    done = { x = 700, y = 1400, w = 200, h = 90 },
}

-- A drag function that moves the draft by the pixel deltas.
local function slide(start, grip, dx, dy)
    return { left = start.left + dx, width = start.width, height = start.height,
        grip = grip, dy = dy }
end

local function newResize()
    return {
        rect = RECT, grip = 70, buttons = BUTTONS,
        draft = { left = 10, width = 68, height = 60 },
    }
end

it("finds the buttons, then the corners, then the inside", function()
    T.eq(ResizeFrame.hit(RECT, { x = 750, y = 1170 }, 70, BUTTONS), "reset")
    T.eq(ResizeFrame.hit(RECT, { x = 380, y = 990 }, 70, BUTTONS), "tl")
    T.eq(ResizeFrame.hit(RECT, { x = 1230, y = 1020 }, 70, BUTTONS), "tr")
    T.eq(ResizeFrame.hit(RECT, { x = 420, y = 1590 }, 70, BUTTONS), "bl")
    T.eq(ResizeFrame.hit(RECT, { x = 1190, y = 1610 }, 70, BUTTONS), "br")
    T.eq(ResizeFrame.hit(RECT, { x = 600, y = 1300 }, 70, BUTTONS), "move")
    T.eq(ResizeFrame.hit(RECT, { x = 100, y = 1300 }, 70, BUTTONS), nil)
end)

it("starts a drag only on a corner or inside", function()
    local frame = newFrame({})
    local resize = newResize()
    T.eq(frame:begin(resize, { x = 750, y = 1170 }), nil, "on Reset")
    T.eq(resize.drag, nil, "no drag on Reset")
    T.eq(frame:begin(resize, { x = 100, y = 1300 }), nil, "outside")
    T.eq(frame:begin(resize, { x = 600, y = 1300 }), "move", "inside")
    T.eq(resize.drag.start.left, 10, "start copied")
end)

it("tracks a drag by its pixel deltas", function()
    local frame = newFrame({})
    local resize = newResize()
    frame:begin(resize, { x = 380, y = 990 })
    T.eq(frame:track(resize, { x = 400, y = 1000 }, slide), true, "moved")
    T.eq(resize.draft.left, 30, "left")
    T.eq(resize.draft.grip, "tl", "grip")
    T.eq(resize.draft.dy, 10, "dy")
    T.eq(frame:track(resize, { x = 400, y = 1000 }, slide), false, "same")
end)

it("finishes a drag at the lift", function()
    local frame = newFrame({})
    local resize = newResize()
    frame:begin(resize, { x = 600, y = 1300 })
    T.eq(frame:finish(resize, { x = 650, y = 1300 }, slide), true)
    T.eq(resize.draft.left, 60, "final position")
    T.eq(resize.drag, nil, "ended")
    T.eq(frame:finish(resize, { x = 700, y = 1300 }, slide), false, "none")
end)

it("draws queued changes together after a delay", function()
    local scheduled = {}
    local frame = newFrame(scheduled)
    local resize = newResize()
    local drawn = 0
    local function redraw() drawn = drawn + 1 end
    frame:queueRedraw(resize, redraw)
    frame:queueRedraw(resize, redraw)
    T.eq(#scheduled, 1, "one timer")
    T.eq(scheduled[1].delay, 0.3, "delay")
    scheduled[1].fn()
    T.eq(drawn, 1, "drawn once")
    frame:queueRedraw(resize, redraw)
    T.eq(#scheduled, 2, "a new timer after drawing")
end)

it("drops a queued redraw when cancelled", function()
    local scheduled = {}
    local frame = newFrame(scheduled)
    local resize = newResize()
    local drawn = 0
    frame:queueRedraw(resize, function() drawn = drawn + 1 end)
    frame:cancelRedraw(resize)
    scheduled[1].fn()
    T.eq(drawn, 0)
end)

it("paints dashes inside the frame and bold corners", function()
    local frame = newFrame({})
    local rects = {}
    local bb = { paintRect = function(_, x, y, w, h, color)
        table.insert(rects, { x = x, y = y, w = w, h = h, color = color })
    end }
    local px = function(mm) return math.floor(mm * 300 / 25.4 + 0.5) end
    frame:paintOutline(bb, RECT, px)
    local corner_bars = 0
    for _, r in ipairs(rects) do
        T.eq(r.color, "black", "ink")
        T.truthy(r.x >= RECT.x and r.y >= RECT.y
            and r.x + r.w <= RECT.x + RECT.w
            and r.y + r.h <= RECT.y + RECT.h, "inside the frame")
        if r.w == px(5) or r.h == px(5) then
            corner_bars = corner_bars + 1
        end
    end
    T.eq(corner_bars, 8, "two bars per corner")
    T.truthy(#rects > 8 + 4, "dashes along every edge")
end)

it("listens for drags over the whole screen and sends them on", function()
    local frame = newFrame({})
    local resize = newResize()
    local sent = {}
    local keyboard = {
        swype_mvp_resize = resize,
        _swypeResizePan = function(_, ges) sent.pan = ges; return true end,
        _swypeResizeRelease = function(_, ges)
            sent.release = ges
            return true
        end,
    }
    frame.screen.getSize = function() return "screen" end
    local widget = frame:create(keyboard, {
        width = 1264, height = 700,
        keys = { x = 461, y = 4, w = 803, h = 692 },
        fade = { x = 4, y = 4, w = 1256, h = 692 },
        on_reset = function() end, on_done = function() end,
    })
    T.eq(widget.ges_events.ResizePan[1].range(), "screen", "pan range")
    T.eq(widget.ges_events.ResizeRelease[1].ges, "pan_release", "release")
    T.eq(widget.ges_events.ResizeSwipe[1].ges, "swipe", "swipe")
    widget:onResizePan(nil, "p")
    widget:onResizeRelease(nil, "r")
    T.eq(sent.pan, "p", "pan sent")
    T.eq(sent.release, "r", "release sent")
    T.eq(resize.grip, 71, "grip in px")
end)
