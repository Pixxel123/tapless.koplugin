local T = require("helper")
local it = T.it

local function newController()
    local InputController = T.load("input_controller")
    local logger = { dbg = function() end, warn = function() end }
    local ui_manager = { scheduleIn = function() end }
    return InputController:new({}, T.normalization, logger, {}, {}, {},
        ui_manager)
end

local function newKeyboard(state)
    local key = {
        key = "a",
        onTapSelect = function() state.tapped = (state.tapped or 0) + 1 end,
    }
    return {
        swype_mvp_session = {
            recordShortSignature = function(_, signature)
                state.recorded = signature
            end,
        },
        _swypeKeyAt = function(_, pos)
            if pos then return "a", key end
        end,
        _swypeRefreshCandidateRow = function() end,
    }
end

it("types a one-letter trace as a tap once the finger lifts", function()
    local state = {}
    local handled = newController():finalizeSignature(newKeyboard(state), "a", {
        letter_points = { { x = 1, y = 1 } },
        released = true,
    })
    T.truthy(handled)
    T.eq(state.tapped, 1, "tapped")
    T.eq(state.recorded, nil, "no leftover swipe state")
end)

it("ignores a one-letter trace finalized by the idle timer", function()
    local state = {}
    newController():finalizeSignature(newKeyboard(state), "a", {
        letter_points = { { x = 1, y = 1 } },
    })
    T.eq(state.tapped, nil, "not tapped")
    T.eq(state.recorded, "a", "recorded as before")
end)
