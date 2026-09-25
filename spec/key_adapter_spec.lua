local T = require("helper")
local it = T.it

-- A stand-in for KOReader's VirtualKey with the methods Tapless wraps.
local function newVirtualKeyClass(calls)
    local VirtualKey = {}
    VirtualKey.__index = VirtualKey
    function VirtualKey:new(options)
        local key = setmetatable(options or {}, self)
        key:init()
        return key
    end
    function VirtualKey:init()
        -- KOReader reads the label size from its global setting here.
        self.font_size = calls.settings:readSetting("keyboard_key_font_size", 22)
        self.bold_setting = calls.settings:isTrue("keyboard_key_bold")
        -- Like KOReader: FrameContainer > CenterContainer > label widget, or
        -- an OverlapGroup of label and alt label when there is an alt label.
        local label = { setText = function() end }
        if self.alt_label then
            local alt = { setText = function() end }
            self[1] = { { { { label }, { alt } } } }
        else
            self[1] = { { label } }
        end
        self.ges_events = {}
        self.swipe_callback = function() calls.alternate_char = true end
    end
    function VirtualKey:onSwipeKey()
        calls.stock_swipe = (calls.stock_swipe or 0) + 1
        return true
    end
    function VirtualKey:onPanReleaseKey()
        calls.stock_pan_release = (calls.stock_pan_release or 0) + 1
        return true
    end
    function VirtualKey:onHoldReleaseKey()
        calls.stock_hold_release = (calls.stock_hold_release or 0) + 1
        return true
    end
    return VirtualKey
end

local function newKeyboard(calls, enabled)
    return {
        isSwypeMvpEnabled = function() return enabled ~= false end,
        onSwypeWordSwipe = function()
            calls.tapless_swipe = (calls.tapless_swipe or 0) + 1
        end,
        onSwypeWordPanRelease = function()
            calls.tapless_pan_release = (calls.tapless_pan_release or 0) + 1
            return true
        end,
        _swypeReset = function() end,
        _swypeCommitPendingContext = function()
            calls.committed = (calls.committed or 0) + 1
        end,
        _swypeClearCandidateRow = function()
            calls.row_cleared = (calls.row_cleared or 0) + 1
        end,
        leftChar = function() calls.cursor = (calls.cursor or 0) - 1 end,
        rightChar = function() calls.cursor = (calls.cursor or 0) + 1 end,
    }
end

local function newSettings(values)
    values = values or {}
    return {
        isTrue = function(_, name) return values[name] == true end,
        readSetting = function(_, name, default)
            if values[name] == nil then return default end
            return values[name]
        end,
    }
end

local function setup(settings)
    local calls = {}
    local VirtualKey = newVirtualKeyClass(calls)
    settings = newSettings(settings)
    calls.settings = settings
    local adapter = T.load("key_adapter")
        :new(T.normalization, T.gesture_range, settings)
    adapter:install(VirtualKey)
    return calls, VirtualKey, adapter
end

it("sends letter swipes to Tapless and other keys to KOReader", function()
    local calls, VirtualKey = setup()
    local keyboard = newKeyboard(calls)
    VirtualKey:new{ key = "a", keyboard = keyboard }:onSwipeKey({}, {})
    VirtualKey:new{ key = "\n", keyboard = keyboard }:onSwipeKey({}, {})
    T.eq(calls.tapless_swipe, 1, "Tapless swipes")
    T.eq(calls.stock_swipe, 1, "stock swipes")
end)

-- A keyboard whose word swipe handlers report whether Tapless took the swipe.
-- starts_on_letter says whether a swipe that begins on the key under the
-- finger counts as starting on a letter, as it does for a number key.
local function newSwipeKeyboard(calls, starts_on_letter, takes)
    local keyboard = newKeyboard(calls)
    keyboard._swypeStartKeyAt = function(_, pos)
        calls.start_looked_up = pos
        return starts_on_letter and "w" or nil
    end
    keyboard.onSwypeWordSwipe = function()
        calls.tapless_swipe = (calls.tapless_swipe or 0) + 1
        return takes
    end
    keyboard.onSwypeWordMultiswipe = function()
        calls.tapless_multiswipe = (calls.tapless_multiswipe or 0) + 1
        return takes
    end
    keyboard._swypeReset = function()
        calls.reset = (calls.reset or 0) + 1
    end
    return keyboard
end

local START = { x = 150, y = 90 }

it("sends a swipe that starts on a letter's number key to Tapless", function()
    local calls, VirtualKey = setup()
    local keyboard = newSwipeKeyboard(calls, true, true)
    local key = VirtualKey:new{ key = "2", keyboard = keyboard }
    T.truthy(key:onSwipeKey({}, { pos = START }))
    T.truthy(key:onMultiswipeKey({}, { start_pos = START }))
    T.eq(calls.tapless_swipe, 1, "Tapless swipes")
    T.eq(calls.tapless_multiswipe, 1, "Tapless multiswipes")
    T.eq(calls.stock_swipe, nil, "stock swipes")
    T.eq(calls.start_looked_up, START, "where the swipe started")
end)

it("hands a number key's swipe back to KOReader when Tapless declines it",
        function()
    local calls, VirtualKey = setup()
    local keyboard = newSwipeKeyboard(calls, true, false)
    keyboard.swype_mvp_trace = {}
    VirtualKey:new{ key = "2", keyboard = keyboard }
        :onSwipeKey({}, { pos = START, direction = "southeast" })
    T.eq(calls.tapless_swipe, 1, "Tapless tried the swipe")
    T.eq(calls.stock_swipe, 1, "stock swipes")
    T.eq(calls.reset, 1, "half-built trace dropped")
end)

it("keeps a number key's alternate-character swipe callback", function()
    local calls, VirtualKey = setup()
    local keyboard = newKeyboard(calls)
    T.truthy(VirtualKey:new{ key = "2", keyboard = keyboard }.swipe_callback)
end)

it("leaves swipes that do not start on a letter to KOReader", function()
    local calls, VirtualKey = setup()
    local keyboard = newSwipeKeyboard(calls, false, true)
    VirtualKey:new{ key = "\n", keyboard = keyboard }
        :onSwipeKey({}, { pos = START })
    VirtualKey:new{ key = "\n", keyboard = keyboard }:onSwipeKey({}, {})
    T.eq(calls.stock_swipe, 2, "stock swipes")
    T.eq(calls.tapless_swipe, nil, "Tapless swipes")
end)

it("leaves number key swipes to KOReader when word swipes are off",
        function()
    local calls, VirtualKey = setup()
    local keyboard = newSwipeKeyboard(calls, true, true)
    keyboard.isSwypeMvpEnabled = function() return false end
    VirtualKey:new{ key = "2", keyboard = keyboard }
        :onSwipeKey({}, { pos = START })
    T.eq(calls.stock_swipe, 1, "stock swipes")
    T.eq(calls.tapless_swipe, nil, "Tapless swipes")
end)

it("disables alternate-character swipes on letter keys only", function()
    local calls, VirtualKey = setup()
    local keyboard = newKeyboard(calls)
    T.eq(VirtualKey:new{ key = "a", keyboard = keyboard }.swipe_callback, nil)
    T.truthy(VirtualKey:new{ key = "\n", keyboard = keyboard }.swipe_callback)
end)

it("keeps a handle on the key label for the suggestion row", function()
    local calls, VirtualKey = setup()
    local key = VirtualKey:new{ key = "a", keyboard = newKeyboard(calls) }
    T.truthy(key.swype_mvp_label_widget, "label widget kept")
    T.eq(key.swype_mvp_label_widget, key[1][1][1])
end)

it("finds the main and alt label widgets of a key with an alt label", function()
    local calls, VirtualKey = setup()
    local key = VirtualKey:new{ key = " ", alt_label = "EN",
        keyboard = newKeyboard(calls) }
    T.eq(key.swype_mvp_label_widget, key[1][1][1][1][1])
    T.eq(key.swype_mvp_alt_label_widget, key[1][1][1][2][1])
end)

it("uses the Tapless key font size only while building a key", function()
    local calls, VirtualKey = setup{ tapless_keyboard_size = "large" }
    local key = VirtualKey:new{ key = "a", keyboard = newKeyboard(calls) }
    T.eq(key.font_size, 26, "large keyboard font")
    T.eq(calls.settings:readSetting("keyboard_key_font_size", 22), 22,
        "global setting untouched afterwards")
end)

it("uses KOReader's key font size until a Tapless size is chosen",
        function()
    local calls, VirtualKey = setup{ keyboard_key_font_size = 30 }
    local key = VirtualKey:new{ key = "a", keyboard = newKeyboard(calls) }
    T.eq(key.font_size, 30)
    calls, VirtualKey = setup{ keyboard_key_font_size = 30,
        tapless_keyboard_font_size = 18 }
    key = VirtualKey:new{ key = "a", keyboard = newKeyboard(calls) }
    T.eq(key.font_size, 18, "a chosen Tapless font size wins")
end)

it("uses KOReader's compact keyboard setting until a size is chosen",
        function()
    local _, _, adapter = setup()
    T.eq(adapter:keyHeight(), 64)
    _, _, adapter = setup{ keyboard_key_compact = true }
    T.eq(adapter:keyHeight(), 48)
    _, _, adapter = setup{ keyboard_key_compact = true,
        tapless_keyboard_size = "extra_compact" }
    T.eq(adapter:keyHeight(), 40, "a chosen Tapless size wins")
    _, _, adapter = setup{ tapless_keyboard_size = "large" }
    T.eq(adapter:keyHeight(), 80)
end)

it("takes letter swipes back from a patch that replaces onSwipeKey", function()
    local calls, VirtualKey, adapter = setup()
    local keyboard = newKeyboard(calls)
    -- Like the ZenOS keyboard patch: replaces without calling the original.
    function VirtualKey:onSwipeKey()
        calls.replacement = (calls.replacement or 0) + 1
        return true
    end
    adapter:ensureInstalled()
    VirtualKey:new{ key = "a", keyboard = keyboard }:onSwipeKey({}, {})
    VirtualKey:new{ key = "\n", keyboard = keyboard }:onSwipeKey({}, {})
    T.eq(calls.tapless_swipe, 1, "letter swipe handled by Tapless")
    T.eq(calls.replacement, 1, "other key handled by the replacement")
    T.eq(calls.stock_swipe, nil, "stock not reached")
end)

it("runs Tapless once when a patch wraps the Tapless handler", function()
    local calls, VirtualKey, adapter = setup()
    local keyboard = newKeyboard(calls)
    local previous = VirtualKey.onPanReleaseKey
    function VirtualKey:onPanReleaseKey(...)
        calls.wrapper = (calls.wrapper or 0) + 1
        return previous(self, ...)
    end
    adapter:ensureInstalled()
    VirtualKey:new{ key = "a", keyboard = keyboard }:onPanReleaseKey({}, {})
    T.eq(calls.tapless_pan_release, 1, "Tapless pan release")
    T.eq(calls.wrapper, nil, "Tapless handled it first")

    keyboard = newKeyboard(calls, false)
    VirtualKey:new{ key = "a", keyboard = keyboard }:onPanReleaseKey({}, {})
    T.eq(calls.tapless_pan_release, 1, "disabled Tapless is skipped")
    T.eq(calls.wrapper, 1, "wrapper reached")
    T.eq(calls.stock_pan_release, 1, "stock reached exactly once")
end)

it("does nothing when no other patch changed the methods", function()
    local _, VirtualKey, adapter = setup()
    local before = VirtualKey.onSwipeKey
    adapter:ensureInstalled()
    T.eq(VirtualKey.onSwipeKey, before)
end)

-- The space bar sits at y 100..140 and is 40 px high: 10 px per character.
local SPACE = { x = 0, y = 100, w = 300, h = 40 }

local function spaceKey(VirtualKey, keyboard, key)
    local space = VirtualKey:new{ key = key or " ", keyboard = keyboard }
    space.dimen = SPACE
    return space
end

local function pan(start_x, x, start_y)
    return {
        ges = "pan",
        start_pos = { x = start_x, y = start_y or 120 },
        pos = { x = x, y = start_y or 120 },
    }
end

local ON = { tapless_space_cursor = true }

it("moves the cursor when sliding along the space bar", function()
    local calls, VirtualKey = setup(ON)
    local keyboard = newKeyboard(calls)
    local space = spaceKey(VirtualKey, keyboard)
    T.truthy(space.ges_events.SpaceCursorPan, "pan registered")
    -- The first pan arrives after KOReader's pan threshold.
    T.truthy(space:onSpaceCursorPan(nil, pan(100, 160)))
    T.eq(calls.cursor, nil, "no jump when sliding starts")
    space:onSpaceCursorPan(nil, pan(100, 195))
    T.eq(calls.cursor, 3, "three characters right")
    space:onSpaceCursorPan(nil, pan(100, 140))
    T.eq(calls.cursor, -2, "five characters back")
    -- A slow slide ends with a pan release under the finger.
    local other = VirtualKey:new{ key = "\n", keyboard = keyboard }
    T.truthy(other:onPanReleaseKey(nil,
        { ges = "pan_release", pos = { x = 141, y = 121 } }))
    T.eq(calls.stock_pan_release, nil, "release not typed")
    T.eq(keyboard.swype_mvp_space_cursor, nil, "slide finished")
end)

it("forgets the swiped word once the cursor slides away", function()
    local calls, VirtualKey = setup(ON)
    local keyboard = newKeyboard(calls)
    local space = spaceKey(VirtualKey, keyboard)
    space:onSpaceCursorPan(nil, pan(100, 160))
    T.eq(calls.row_cleared, nil, "not before the cursor moves")
    space:onSpaceCursorPan(nil, pan(100, 140))
    -- Backspace and suggestions must no longer act on the swiped word.
    T.eq(calls.committed, 1)
    T.eq(calls.row_cleared, 1)
    space:onSpaceCursorPan(nil, pan(100, 120))
    T.eq(calls.row_cleared, 1, "once per slide")
end)

it("swallows the swipe that ends a fast slide", function()
    local calls, VirtualKey = setup(ON)
    local keyboard = newKeyboard(calls)
    local space = spaceKey(VirtualKey, keyboard)
    space:onSpaceCursorPan(nil, pan(100, 160))
    space:onSpaceCursorPan(nil, pan(100, 190))
    T.truthy(space:onSwipeKey(nil,
        { ges = "swipe", pos = { x = 100, y = 120 } }))
    T.eq(calls.stock_swipe, nil)
end)

it("leaves word swipes that start on a letter to Tapless", function()
    local calls, VirtualKey = setup(ON)
    local keyboard = newKeyboard(calls)
    local space = spaceKey(VirtualKey, keyboard)
    T.eq(space:onSpaceCursorPan(nil, pan(20, 200, 50)), false)
    T.eq(keyboard.swype_mvp_space_cursor, nil)
end)

it("does not swallow a later gesture after an unfinished slide", function()
    local calls, VirtualKey = setup(ON)
    local keyboard = newKeyboard(calls)
    local space = spaceKey(VirtualKey, keyboard)
    space:onSpaceCursorPan(nil, pan(100, 160))
    space:onSpaceCursorPan(nil, pan(100, 190))
    -- The finger lifted above the keyboard: no release reached a key.
    VirtualKey:new{ key = "a", keyboard = keyboard }:onSwipeKey(nil,
        { ges = "swipe", pos = { x = 20, y = 50 } })
    T.eq(calls.tapless_swipe, 1, "word swipe still reaches Tapless")
end)

it("forgets an unfinished slide once the keyboard is rebuilt", function()
    local calls, VirtualKey = setup(ON)
    local keyboard = newKeyboard(calls)
    local space = spaceKey(VirtualKey, keyboard)
    space:onSpaceCursorPan(nil, pan(100, 160))
    space:onSpaceCursorPan(nil, pan(100, 190))
    -- The finger lifted above the keyboard, then the keys were rebuilt
    -- (shift, symbols, another language), giving a new space key.
    local new_space = spaceKey(VirtualKey, keyboard)
    -- A word swipe from a letter passes its pans to the new space key
    -- first, then ends with a pan release near where the slide was.
    new_space:onSpaceCursorPan(nil, pan(20, 185, 50))
    VirtualKey:new{ key = "a", keyboard = keyboard }:onPanReleaseKey(nil,
        { ges = "pan_release", pos = { x = 191, y = 121 } })
    T.eq(calls.tapless_pan_release, 1, "word swipe still reaches Tapless")
end)

it("types a space when the finger barely moved", function()
    local calls, VirtualKey = setup(ON)
    local keyboard = newKeyboard(calls)
    local space = spaceKey(VirtualKey, keyboard)
    space:onSpaceCursorPan(nil, pan(100, 160))
    space:onSpaceCursorPan(nil, pan(100, 164))
    space:onPanReleaseKey(nil, { ges = "pan_release", pos = { x = 164, y = 120 } })
    T.eq(calls.cursor, nil)
    T.eq(calls.tapless_pan_release, 1, "normal release handling")
end)

it("works with the full-width Japanese space key", function()
    local calls, VirtualKey = setup(ON)
    local space = spaceKey(VirtualKey, newKeyboard(calls), "\u{3000}")
    space:onSpaceCursorPan(nil, pan(100, 160))
    space:onSpaceCursorPan(nil, pan(100, 180))
    T.eq(calls.cursor, 2)
end)

it("leaves the space bar alone when the option is off", function()
    local calls, VirtualKey = setup()
    local space = spaceKey(VirtualKey, newKeyboard(calls))
    T.eq(space.ges_events.SpaceCursorPan, nil, "no pan registered")
    T.eq(space:onSpaceCursorPan(nil, pan(100, 160)), false)
    T.eq(rawget(VirtualKey, "onHoldSelect"), nil, "hold not wrapped")
end)

it("still slides when empty suggestion slots see the pans first",
        function()
    local calls, VirtualKey = setup(ON)
    local keyboard = newKeyboard(calls)
    -- Empty slots show " " and are marked as suggestions after they are
    -- built, so they register for pans too, and sit above the space bar.
    local slot = spaceKey(VirtualKey, keyboard)
    slot.is_swype_candidate = true
    local space = spaceKey(VirtualKey, keyboard)
    for _, x in ipairs({ 160, 195 }) do
        if not slot:onSpaceCursorPan(nil, pan(100, x)) then
            space:onSpaceCursorPan(nil, pan(100, x))
        end
    end
    T.eq(calls.cursor, 3, "three characters right")
end)

it("ignores empty suggestion slots that look like a space", function()
    local calls, VirtualKey = setup(ON)
    local slot = spaceKey(VirtualKey, newKeyboard(calls))
    slot.is_swype_candidate = true
    T.eq(slot:onSpaceCursorPan(nil, pan(100, 160)), false)
end)

-- A keyboard with a one-handed switch waiting for the lift.
local function withPendingSwitch(keyboard, calls)
    local pending = true
    keyboard._swypeTakeLift = function()
        if not pending then
            return false
        end
        pending = false
        calls.switched = (calls.switched or 0) + 1
        return true
    end
    return keyboard
end

it("switches one-handed mode on the lift after holding the globe key",
        function()
    local calls, VirtualKey = setup()
    local keyboard = withPendingSwitch(newKeyboard(calls), calls)
    local key = VirtualKey:new{ key = "a", keyboard = keyboard }
    T.eq(key:onHoldReleaseKey(), true, "taken")
    T.eq(calls.switched, 1, "switched")
    T.eq(calls.stock_hold_release, nil, "no stock release")
    key:onHoldReleaseKey()
    T.eq(calls.stock_hold_release, 1, "next release is ordinary")
end)

it("leaves a pending switch pending through a pan release", function()
    local calls, VirtualKey = setup()
    local keyboard = withPendingSwitch(newKeyboard(calls), calls)
    local key = VirtualKey:new{ key = "a", keyboard = keyboard }
    -- A hold never yields a pan_release, so a pending switch must not be
    -- taken here; the word release runs as usual and the switch waits for
    -- the hold_release that always follows a hold.
    T.eq(key:onPanReleaseKey({}, { ges = "pan_release" }), true, "taken")
    T.eq(calls.switched, nil, "not switched")
    T.eq(calls.tapless_pan_release, 1, "word release ran")
    T.eq(key:onHoldReleaseKey(), true, "switch still pending")
    T.eq(calls.switched, 1, "switched on the later hold release")
end)

it("leaves hold releases alone with no switch waiting", function()
    local calls, VirtualKey = setup()
    local key = VirtualKey:new{ key = "a", keyboard = newKeyboard(calls) }
    T.eq(key:onHoldReleaseKey(), true)
    T.eq(calls.stock_hold_release, 1)
end)

it("builds a key bold when asked, whatever the global setting", function()
    local calls, VirtualKey = setup()
    local keyboard = newKeyboard(calls)
    T.eq(VirtualKey:new{ key = "a", keyboard = keyboard,
        tapless_bold = true }.bold_setting, true, "bold key")
    T.eq(VirtualKey:new{ key = "b", keyboard = keyboard }.bold_setting,
        false, "plain key")
    T.eq(calls.settings:isTrue("keyboard_key_bold"), false, "restored")
end)

it("never takes the one-handed handle for a letter", function()
    local _, _, adapter = setup()
    T.eq(adapter:isTextKey({ key = "a", is_tapless_handle = true }), false)
end)
