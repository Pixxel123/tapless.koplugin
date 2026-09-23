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
