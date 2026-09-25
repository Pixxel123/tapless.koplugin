-- One-handed keyboard mode: whether it is on, and where the keys block
-- sits and how big it is. Sizes are in millimetres, so a thumb's reach is
-- the same on any screen; portrait and landscape each keep their own.
-- A screen is { w = px, h = px, dpi = dots per inch }.
local OneHanded = {
    SETTING = "tapless_one_handed",
    MIN_WIDTH = 64,
    MAX_WIDTH = 92,
    DEFAULT_WIDTH = 68,
    -- Always left beside the keys, so a panel button fits.
    PANEL_ROOM = 12,
    MIN_HEIGHT = 45,
    MAX_HEIGHT = 75,
    -- Of the screen height, so a dialog keeps room above in landscape.
    MAX_HEIGHT_SHARE = 0.55,
    SNAP = 3,
    -- Shown in the corner of the globe key, whose hold switches the mode.
    HINT = "◨",
}
OneHanded.__index = OneHanded

function OneHanded:new(settings)
    return setmetatable({ settings = assert(settings) }, self)
end

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function round(value)
    return math.floor(value + 0.5)
end

local function number(value)
    if type(value) == "number" and value == value then
        return value
    end
end

local function tenth(value)
    return value and round(value * 10) / 10
end

local function orientation(screen)
    return screen.w > screen.h and "landscape" or "portrait"
end

function OneHanded.toMM(px, screen)
    return px * 25.4 / screen.dpi
end

function OneHanded.toPx(mm, screen)
    return round(mm * screen.dpi / 25.4)
end

function OneHanded.limits(screen)
    local screen_w = OneHanded.toMM(screen.w, screen)
    local screen_h = OneHanded.toMM(screen.h, screen)
    local max_w = math.min(OneHanded.MAX_WIDTH,
        screen_w - OneHanded.PANEL_ROOM)
    local max_h = math.min(OneHanded.MAX_HEIGHT,
        screen_h * OneHanded.MAX_HEIGHT_SHARE)
    return {
        screen_w = screen_w,
        min_w = math.min(OneHanded.MIN_WIDTH, max_w),
        max_w = max_w,
        min_h = math.min(OneHanded.MIN_HEIGHT, max_h),
        max_h = max_h,
    }
end

-- Keeps a keys block inside the limits and on screen. A missing left
-- means against the right edge; a missing height, the keyboard's normal
-- height.
function OneHanded.fit(block, screen)
    local limits = OneHanded.limits(screen)
    local width = clamp(number(block.width) or OneHanded.DEFAULT_WIDTH,
        limits.min_w, limits.max_w)
    local height = number(block.height)
    if height then
        height = clamp(height, limits.min_h, limits.max_h)
    end
    local left = number(block.left) or limits.screen_w - width
    left = clamp(left, 0, limits.screen_w - width)
    return { left = left, width = width, height = height }
end

function OneHanded:state(screen)
    local saved = self.settings:readSetting(self.SETTING)
    local entry = type(saved) == "table" and saved[orientation(screen)]
    if type(entry) ~= "table" then
        entry = {}
    end
    local state = OneHanded.fit({
        left = entry.left_mm,
        width = entry.width_mm,
        height = entry.height_mm,
    }, screen)
    state.enabled = entry.enabled == true
    return state
end

-- Applies change to this orientation's state, then saves it.
function OneHanded:update(screen, change)
    local state = self:state(screen)
    change(state)
    local block = OneHanded.fit(state, screen)
    local saved = self.settings:readSetting(self.SETTING)
    if type(saved) ~= "table" then
        saved = {}
    end
    saved[orientation(screen)] = {
        enabled = state.enabled == true,
        left_mm = tenth(block.left),
        width_mm = tenth(block.width),
        height_mm = tenth(block.height),
    }
    self.settings:saveSetting(self.SETTING, saved)
    return self:state(screen)
end

function OneHanded:setEnabled(screen, enabled)
    return self:update(screen, function(state)
        state.enabled = enabled
    end)
end

function OneHanded:toggle(screen)
    return self:update(screen, function(state)
        state.enabled = not state.enabled
    end)
end

-- Turns the mode on with the keys block where block says.
function OneHanded:saveBlock(screen, block)
    return self:update(screen, function(state)
        state.enabled = true
        state.left = block.left
        state.width = block.width
        state.height = block.height
    end)
end

-- The edge the keys would move to: the one farther from their centre.
function OneHanded.target(block, screen)
    local centre = block.left + block.width / 2
    return centre > OneHanded.toMM(screen.w, screen) / 2 and "left" or "right"
end

function OneHanded.toEdge(block, screen, edge)
    local screen_w = OneHanded.toMM(screen.w, screen)
    return OneHanded.fit({
        left = edge == "left" and 0 or screen_w - block.width,
        width = block.width,
        height = block.height,
    }, screen)
end

function OneHanded:moveToTarget(screen)
    return self:update(screen, function(state)
        local target = OneHanded.target(state, screen)
        state.left = OneHanded.toEdge(state, screen, target).left
    end)
end

-- Pulls the keys to an edge within SNAP mm of it. Moving both edges is
-- right for a move, which drags the whole block; a corner drag must only
-- snap the edge it is dragging, growing or shrinking the width, or it
-- would carry the fixed opposite edge along with it.
function OneHanded.snap(block, screen, grip)
    local limits = OneHanded.limits(screen)
    local fitted = OneHanded.fit(block, screen)
    local screen_w = OneHanded.toMM(screen.w, screen)
    if grip == "tr" or grip == "br" then
        if screen_w - fitted.left - fitted.width < OneHanded.SNAP then
            fitted.width = clamp(screen_w - fitted.left, limits.min_w,
                limits.max_w)
        end
        return fitted
    end
    if grip == "tl" or grip == "bl" then
        if fitted.left < OneHanded.SNAP then
            -- The right edge is the fixed one here, so it must stay put
            -- even where capping the width keeps the left edge off 0.
            local right = fitted.left + fitted.width
            fitted.width = clamp(right, limits.min_w, limits.max_w)
            fitted.left = right - fitted.width
        end
        return fitted
    end
    if fitted.left < OneHanded.SNAP then
        fitted.left = 0
    end
    if screen_w - fitted.left - fitted.width < OneHanded.SNAP then
        fitted.left = screen_w - fitted.width
    end
    return fitted
end

-- The draft after dragging grip dx, dy millimetres from start. Top corners
-- set width and height, bottom corners the width only, keeping the
-- opposite edges where they are; "move" slides the keys along the bottom.
-- A nil start.height means the normal height and passes through unchanged,
-- except a top corner, which needs a number to drag from and so starts it
-- from normal_height instead.
function OneHanded.drag(start, grip, dx, dy, screen, normal_height)
    local limits = OneHanded.limits(screen)
    local block = {
        left = start.left,
        width = start.width,
        height = start.height,
    }
    if grip == "move" then
        block.left = start.left + dx
    else
        if grip == "tl" or grip == "bl" then
            local right = start.left + start.width
            block.width = clamp(start.width - dx, limits.min_w,
                math.min(limits.max_w, right))
            block.left = right - block.width
        else
            block.width = clamp(start.width + dx, limits.min_w,
                math.min(limits.max_w, limits.screen_w - start.left))
        end
        if grip == "tl" or grip == "tr" then
            block.height = clamp((start.height or normal_height) - dy,
                limits.min_h, limits.max_h)
        end
    end
    return OneHanded.snap(block, screen, grip)
end

-- Back to the default width and the normal (nil) height, against whichever
-- edge the keys are nearer.
function OneHanded.reset(block, screen)
    local nearer = OneHanded.target(block, screen) == "left"
        and "right" or "left"
    local fresh = OneHanded.fit({
        width = OneHanded.DEFAULT_WIDTH,
    }, screen)
    return OneHanded.toEdge(fresh, screen, nearer)
end

-- The keys frame in pixels: its left edge and width, the width inside
-- its border and padding (inset each side), the room after it, and the
-- side of it with more room, where the handle goes.
function OneHanded.layout(block, screen, inset)
    local frame_w = math.min(OneHanded.toPx(block.width, screen), screen.w)
    local frame_x = clamp(OneHanded.toPx(block.left, screen),
        0, screen.w - frame_w)
    local after = screen.w - frame_x - frame_w
    return {
        frame_x = frame_x,
        frame_w = frame_w,
        inner_w = frame_w - 2 * inset,
        after = after,
        handle_side = frame_x >= after and "left" or "right",
    }
end

return OneHanded
