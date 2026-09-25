-- Resize mode for the one-handed keyboard: a dashed frame with bold
-- corners over the faded keys, with Reset, a move icon and Done stacked
-- in its middle. Dragging a corner resizes the keys and dragging inside
-- moves them. The keys are rebuilt live, at a limited rate for e-ink; the
-- drag state lives on the keyboard so it survives each rebuild.
local ResizeFrame = {
    REDRAW_DELAY = 0.3,
    FADE = 0.6,
    GRIP_MM = 6,
    DASH_MM = 2,
    GAP_MM = 1.5,
    LINE_MM = 0.4,
    ARM_MM = 5,
    CORNER_MM = 1.2,
    BUTTON_W_MM = 18,
    BUTTON_H_MM = 8,
    MOVE_MM = 12,
    SPACING_MM = 1.5,
}
ResizeFrame.__index = ResizeFrame

function ResizeFrame:new(options)
    return setmetatable({
        ui_manager = assert(options.ui_manager),
        input_container = assert(options.input_container),
        overlap_group = assert(options.overlap_group),
        vertical_group = assert(options.vertical_group),
        vertical_span = assert(options.vertical_span),
        horizontal_span = assert(options.horizontal_span),
        gesture_range = assert(options.gesture_range),
        blitbuffer = assert(options.blitbuffer),
        panel_button = assert(options.panel_button),
        screen = assert(options.screen),
        icon_dir = assert(options.icon_dir),
    }, self)
end

local function inside(rect, pos)
    return rect and pos
        and pos.x >= rect.x and pos.x < rect.x + rect.w
        and pos.y >= rect.y and pos.y < rect.y + rect.h
end

local CORNERS = { "tl", "tr", "bl", "br" }

-- What a touch at pos takes hold of: "reset" or "done" on those buttons, a
-- corner within grip px of it, "move" elsewhere in the frame, or nil.
function ResizeFrame.hit(rect, pos, grip, buttons)
    if not rect or not pos then
        return nil
    end
    for name, button in pairs(buttons or {}) do
        if inside(button, pos) then
            return name
        end
    end
    local right, bottom = rect.x + rect.w, rect.y + rect.h
    local at = {
        tl = { rect.x, rect.y }, tr = { right, rect.y },
        bl = { rect.x, bottom }, br = { right, bottom },
    }
    for _, name in ipairs(CORNERS) do
        local corner = at[name]
        if math.abs(pos.x - corner[1]) <= grip
                and math.abs(pos.y - corner[2]) <= grip then
            return name
        end
    end
    if inside(rect, pos) then
        return "move"
    end
end

-- resize is the keyboard's swype_mvp_resize: draft, rect, grip and buttons
-- (set when painted), drag, and the redraw generation.
function ResizeFrame:begin(resize, pos)
    local grip = ResizeFrame.hit(resize.rect, pos, resize.grip or 0,
        resize.buttons)
    if grip == nil or grip == "reset" or grip == "done" then
        return nil
    end
    local draft = resize.draft
    resize.drag = {
        grip = grip,
        x = pos.x,
        y = pos.y,
        start = { left = draft.left, width = draft.width,
            height = draft.height },
    }
    return grip
end

local function same(a, b)
    return a.left == b.left and a.width == b.width and a.height == b.height
end

-- drag(start, grip, dx, dy) turns pixel deltas into a new draft.
function ResizeFrame:track(resize, pos, drag)
    local state = resize.drag
    if not state or not pos then
        return false
    end
    local draft = drag(state.start, state.grip,
        pos.x - state.x, pos.y - state.y)
    if same(draft, resize.draft) then
        return false
    end
    resize.draft = draft
    return true
end

function ResizeFrame:finish(resize, pos, drag)
    if not resize.drag then
        return false
    end
    self:track(resize, pos, drag)
    resize.drag = nil
    return true
end

-- Runs redraw REDRAW_DELAY after the first change since the last redraw;
-- changes in between are drawn together.
function ResizeFrame:queueRedraw(resize, redraw)
    if resize.queued then
        return
    end
    resize.queued = true
    resize.generation = resize.generation or 0
    local generation = resize.generation
    self.ui_manager:scheduleIn(self.REDRAW_DELAY, function()
        if resize.generation ~= generation or not resize.queued then
            return
        end
        resize.queued = false
        redraw()
    end)
end

function ResizeFrame:cancelRedraw(resize)
    resize.generation = (resize.generation or 0) + 1
    resize.queued = false
end

-- A dashed outline just inside rect, and an L of two bars in each corner.
function ResizeFrame:paintOutline(bb, rect, px)
    local black = self.blitbuffer.COLOR_BLACK
    local line, dash, gap = px(self.LINE_MM), px(self.DASH_MM),
        px(self.GAP_MM)
    local function dashes(x, y, length, across)
        local at = 0
        while at < length do
            local run = math.min(dash, length - at)
            if across then
                bb:paintRect(x + at, y, run, line, black)
            else
                bb:paintRect(x, y + at, line, run, black)
            end
            at = at + dash + gap
        end
    end
    local right, bottom = rect.x + rect.w, rect.y + rect.h
    dashes(rect.x, rect.y, rect.w, true)
    dashes(rect.x, bottom - line, rect.w, true)
    dashes(rect.x, rect.y, rect.h, false)
    dashes(right - line, rect.y, rect.h, false)
    local arm, thick = px(self.ARM_MM), px(self.CORNER_MM)
    bb:paintRect(rect.x, rect.y, arm, thick, black)
    bb:paintRect(rect.x, rect.y, thick, arm, black)
    bb:paintRect(right - arm, rect.y, arm, thick, black)
    bb:paintRect(right - thick, rect.y, thick, arm, black)
    bb:paintRect(rect.x, bottom - thick, arm, thick, black)
    bb:paintRect(rect.x, bottom - arm, thick, arm, black)
    bb:paintRect(right - arm, bottom - thick, arm, thick, black)
    bb:paintRect(right - thick, bottom - arm, thick, arm, black)
end

-- The overlay drawn after the keyboard frame. options: width and height
-- of the keyboard; keys and fade, {x, y, w, h} within it; on_reset and
-- on_done.
function ResizeFrame:create(keyboard, options)
    local frame = self
    local dpi = self.screen:getDPI()
    local function px(mm)
        return math.max(1, math.floor(mm * dpi / 25.4 + 0.5))
    end
    local resize = keyboard.swype_mvp_resize
    resize.grip = px(self.GRIP_MM)
    local border = px(0.4)
    local reset = self.panel_button:create{
        name = "reset", text = "Reset", bordersize = border,
        width = px(self.BUTTON_W_MM), height = px(self.BUTTON_H_MM),
        callback = options.on_reset,
    }
    local move = self.panel_button:create{
        name = "move", icon = self.icon_dir .. "/move.svg",
        icon_size = px(self.MOVE_MM * 0.6), bordersize = border,
        radius = px(self.MOVE_MM / 2),
        width = px(self.MOVE_MM), height = px(self.MOVE_MM),
    }
    local done = self.panel_button:create{
        name = "done", text = "Done", bold = true, bordersize = border,
        width = px(self.BUTTON_W_MM), height = px(self.BUTTON_H_MM),
        callback = options.on_done,
    }
    local spacing = px(self.SPACING_MM)
    local column = self.vertical_group:new{
        allow_mirroring = false,
        reset,
        self.vertical_span:new{ width = spacing },
        move,
        self.vertical_span:new{ width = spacing },
        done,
    }
    local keys = options.keys
    local size = column.getSize and column:getSize()
        or { w = px(self.BUTTON_W_MM),
            h = 2 * px(self.BUTTON_H_MM) + px(self.MOVE_MM) + 2 * spacing }
    column.overlap_offset = {
        keys.x + math.floor((keys.w - size.w) / 2),
        keys.y + math.floor((keys.h - size.h) / 2),
    }
    local layer = self.overlap_group:new{
        allow_mirroring = false,
        self.horizontal_span:new{ width = options.width },
        self.vertical_span:new{ width = options.height },
        column,
    }
    local widget = self.input_container:new{ layer }
    local function whole_screen()
        return frame.screen:getSize()
    end
    widget.ges_events = {
        ResizePan = {
            self.gesture_range:new{ ges = "pan", range = whole_screen },
        },
        ResizeRelease = {
            self.gesture_range:new{ ges = "pan_release",
                range = whole_screen },
        },
        ResizeSwipe = {
            self.gesture_range:new{ ges = "swipe", range = whole_screen },
        },
    }
    widget.onResizePan = function(_, _, ges)
        return keyboard:_swypeResizePan(ges)
    end
    widget.onResizeRelease = function(_, _, ges)
        return keyboard:_swypeResizeRelease(ges)
    end
    widget.onResizeSwipe = widget.onResizeRelease
    widget.paintTo = function(this, bb, x, y)
        local fade = options.fade
        bb:lightenRect(x + fade.x, y + fade.y, fade.w, fade.h, frame.FADE)
        local rect = { x = x + keys.x, y = y + keys.y,
            w = keys.w, h = keys.h }
        resize.rect = rect
        frame:paintOutline(bb, rect, px)
        frame.input_container.paintTo(this, bb, x, y)
        resize.buttons = { reset = reset.dimen, done = done.dimen }
    end
    return widget
end

return ResizeFrame
