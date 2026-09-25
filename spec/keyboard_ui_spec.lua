local T = require("helper")
local it = T.it

-- A screen rectangle with KOReader Geom's combine.
local function rect(x, w)
    return {
        x = x, y = 0, w = w, h = 10,
        combine = function(self, other)
            local left = math.min(self.x, other.x)
            local right = math.max(self.x + self.w, other.x + other.w)
            return rect(left, right - left)
        end,
    }
end

local function setup(changes)
    local dirty = {}
    local keys = { { { dimen = rect(0, 50) } }, { { dimen = rect(50, 50) } } }
    local ui = T.load("keyboard_ui"):new{
        candidate_row = {
            refresh = function() return table.remove(changes, 1) end,
        },
        confirm_box = {},
        horizontal_group = {},
        virtual_key = {},
        ui_manager = {
            setDirty = function(_, _, refresh_type, region)
                table.insert(dirty, { refresh_type, region })
            end,
        },
        gesture_range = {},
        screen = {},
    }
    local session = {
        getCandidates = function() end,
        getPersonalOffer = function() end,
    }
    local keyboard = {
        swype_mvp_candidate_keys = keys,
        swype_mvp_session = session,
    }
    return ui, keyboard, dirty
end

it("registers a screen-wide hold_release range for the switch lift",
        function()
    local ui = T.load("keyboard_ui"):new{
        candidate_row = {},
        confirm_box = {},
        horizontal_group = {},
        virtual_key = {},
        ui_manager = {},
        gesture_range = T.gesture_range,
        screen = { getSize = function() return "screen" end },
    }
    local keyboard = { ges_events = {}, dimen = {} }
    ui:registerGestureRanges(keyboard)
    local range = keyboard.ges_events.SwypeHoldRelease[1]
    T.eq(range.ges, "hold_release", "gesture")
    T.eq(range.range(), "screen", "whole screen")
end)

it("cleans the suggestion row with a flash every few changes", function()
    local every = T.load("keyboard_ui").ROW_CLEANUP_EVERY
    local changes = {}
    for index = 1, every * 2 do
        -- Every other refresh changes nothing and does not count.
        changes[index] = index % 2 == 0
    end
    local ui, keyboard, dirty = setup(changes)
    for _ = 1, every * 2 - 1 do
        ui:refreshCandidateRow(keyboard)
    end
    T.eq(#dirty, 0, "no clean-up yet")
    ui:refreshCandidateRow(keyboard)
    T.eq(#dirty, 1)
    T.eq(dirty[1][1], "flashui")
    T.eq(dirty[1][2].x, 0)
    T.eq(dirty[1][2].w, 100, "whole row")
end)

it("passes the handle on to the candidate row", function()
    local received
    local ui = T.load("keyboard_ui"):new{
        candidate_row = {
            create = function(_, options) received = options end,
        },
        confirm_box = {},
        horizontal_group = {},
        virtual_key = {},
        ui_manager = {},
        gesture_range = {},
        screen = {},
    }
    local keyboard = {
        swype_mvp_session = {
            getCandidates = function() end,
            getPersonalOffer = function() end,
        },
    }
    local handle = { widget = {}, width = 40, side = "left" }
    ui:createCandidateRow(keyboard, {
        width = 400, height = 40, key_padding = 2, padding = 2,
        horizontal_padding = {}, handle = handle,
    })

    T.eq(received.handle, handle)
end)
