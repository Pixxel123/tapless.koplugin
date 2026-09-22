local T = require("helper")
local it = T.it

-- Stand-ins for the KOReader pieces the backport patches.
local function setup(options)
    options = options or {}
    local calls = {}
    local Contact = {}
    function Contact:tapState()
        calls.original_tap_state = (calls.original_tap_state or 0) + 1
        return { ges = "two_finger_tap" }
    end
    local GestureDetector = {}
    function GestureDetector:newContact() return Contact end
    local input = { allow_concurrent_taps = options.built_in }
    local ui_manager = { _window_stack = {} }
    function ui_manager:show(widget)
        table.insert(self._window_stack, { widget = widget })
    end
    function ui_manager:close(widget)
        for index, window in ipairs(self._window_stack) do
            if window.widget == widget then
                table.remove(self._window_stack, index)
                break
            end
        end
    end
    local Keyboard = {}
    local installed = T.load("concurrent_taps").install{
        input = input,
        gesture_detector = GestureDetector,
        ui_manager = ui_manager,
        geometry = { new = function(_, o) return o end },
        logger = { warn = function() end },
        widget_classes = { Keyboard },
    }
    local function newContact(fields)
        local contact = setmetatable(fields, { __index = Contact })
        contact.ges_dec = {
            input = input,
            dropContact = function() calls.dropped = true end,
        }
        return contact
    end
    return {
        installed = installed, input = input, ui_manager = ui_manager,
        Keyboard = Keyboard, calls = calls, newContact = newContact,
    }
end

local function lift()
    return { id = -1, x = 5, y = 7, timev = 1 }
end

it("does nothing on KOReader versions that have it built in", function()
    local env = setup{ built_in = false }
    T.eq(env.installed, false)
    T.eq(env.Keyboard.allow_concurrent_taps, nil)
end)

it("follows the keyboard being shown and closed", function()
    local env = setup()
    T.truthy(env.installed)
    local keyboard = setmetatable({}, { __index = env.Keyboard })
    local dialog = {}
    env.ui_manager:show(dialog)
    T.eq(env.input.allow_concurrent_taps, false, "dialog")
    env.ui_manager:show(keyboard)
    T.eq(env.input.allow_concurrent_taps, true, "keyboard on top")
    env.ui_manager:close(keyboard)
    T.eq(env.input.allow_concurrent_taps, false, "keyboard closed")
end)

it("reports a lifted contact as its own tap while enabled", function()
    local env = setup()
    env.input.allow_concurrent_taps = true
    local contact = env.newContact{
        current_tev = lift(), buddy_contact = {}, down = true,
    }
    local gesture = contact:tapState()
    T.eq(gesture.ges, "tap")
    T.eq(gesture.pos.x, 5)
    T.truthy(env.calls.dropped, "contact dropped")
    T.eq(env.calls.original_tap_state, nil)
end)

it("keeps KOReader's handling otherwise", function()
    local env = setup()
    env.input.allow_concurrent_taps = false
    local contact = env.newContact{
        current_tev = lift(), buddy_contact = {}, down = true,
    }
    T.eq(contact:tapState().ges, "two_finger_tap")
    env.input.allow_concurrent_taps = true
    contact = env.newContact{ current_tev = lift(), down = true }
    T.eq(contact:tapState().ges, "two_finger_tap", "single finger")
end)
