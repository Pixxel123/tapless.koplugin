local KeyAdapter = {}
KeyAdapter.__index = KeyAdapter

KeyAdapter.SPACE_CURSOR_SETTING = "tapless_space_cursor"

-- Wrappers for methods VirtualKey does not define itself.
local OPTIONAL_METHODS = {
    onMultiswipeKey = true,
    onSpaceCursorPan = true,
}

function KeyAdapter:new(normalization, gesture_range, settings)
    return setmetatable({
        normalization = assert(normalization),
        gesture_range = assert(gesture_range),
        settings = assert(settings),
        installed = {},
        active = {},
    }, self)
end

function KeyAdapter:isTextKey(key)
    return key and not key.is_swype_candidate
        and #self.normalization:normalizeText(
            key.key or key.label,
            key.keyboard and key.keyboard.swype_mvp_normalization_profile) == 1
end

-- Space keys in every KOReader layout, including the full-width space used
-- by the Japanese kana layers.
function KeyAdapter:isSpaceKey(key)
    return key and not key.is_swype_candidate
        and (key.key == " " or key.key == "\u{3000}")
end

function KeyAdapter:spaceCursorEnabled()
    return self.settings:isTrue(self.SPACE_CURSOR_SETTING)
end

local function contains(dimen, pos)
    return dimen and pos
        and pos.x >= dimen.x and pos.x < dimen.x + dimen.w
        and pos.y >= dimen.y and pos.y < dimen.y + dimen.h
end

-- Slide on the space bar to move the cursor, one character per quarter key
-- height. Holding space is left alone (it switches language). Pans that
-- start elsewhere are word swipes and belong to Tapless.
function KeyAdapter:moveSpaceCursor(key, ges)
    local keyboard = key.keyboard
    local start = ges and ges.start_pos
    local pos = ges and ges.pos
    if not keyboard or not start or not pos then
        return false
    end
    local state = keyboard.swype_mvp_space_cursor
    local same_slide = state and state.key == key
        and state.start_x == start.x and state.start_y == start.y
    if not same_slide then
        if not (self:isSpaceKey(key) and self:spaceCursorEnabled()
                and contains(key.dimen, start)) then
            -- A new gesture began, so a slide whose lift no key saw is
            -- over, even if the keys have been rebuilt since. Only a space
            -- key may say so: empty suggestion slots also show " " and see
            -- every pan before the space bar does.
            if self:isSpaceKey(key) then
                keyboard.swype_mvp_space_cursor = nil
            end
            return false
        end
        -- KOReader only reports a pan once the finger has moved past its
        -- pan threshold. Start counting from there so the cursor does not
        -- jump a few characters as soon as sliding begins.
        keyboard.swype_mvp_space_cursor = {
            key = key,
            start_x = start.x,
            start_y = start.y,
            x = pos.x,
            last = pos,
            remainder = 0,
            moved = false,
        }
        return true
    end
    local step = math.max(1, math.floor(key.dimen.h * 0.25))
    local delta = pos.x - state.x + state.remainder
    local chars = delta >= 0 and math.floor(delta / step)
        or math.ceil(delta / step)
    state.x = pos.x
    state.last = pos
    state.remainder = delta - chars * step
    -- The keyboard's own left/right methods are wrapped by the input
    -- method layouts (Chinese, Japanese, Korean, Vietnamese) to finish the
    -- current composition first.
    for _ = 1, math.abs(chars) do
        if chars > 0 then
            keyboard:rightChar()
        else
            keyboard:leftChar()
        end
    end
    if chars ~= 0 and not state.moved then
        state.moved = true
        -- The cursor has left the swiped word: keep the word, but backspace
        -- and the suggestions must no longer act on it.
        keyboard:_swypeCommitPendingContext()
        keyboard:_swypeClearCandidateRow()
    end
    return true
end

-- The lift that ends a slide on space arrives as a swipe (fast slide, at
-- the start position) or a pan release (slow slide, at the finger). Swallow
-- it so it does not type a key or start a word.
function KeyAdapter:finishSpaceCursor(keyboard, ges)
    local state = keyboard and keyboard.swype_mvp_space_cursor
    if not state then
        return false
    end
    keyboard.swype_mvp_space_cursor = nil
    local pos = ges and ges.pos
    if not state.moved or not pos then
        return false
    end
    if ges.ges == "swipe" or ges.ges == "multiswipe" then
        return pos.x == state.start_x and pos.y == state.start_y
    end
    local slop = state.key.dimen.h
    return math.abs(pos.x - state.last.x) <= slop
        and math.abs(pos.y - state.last.y) <= slop
end

-- Key height before scaling, and key font size when the text size is
-- automatic, for each Tapless keyboard size.
local KEY_HEIGHTS = {
    extra_compact = 40, compact = 48, normal = 64, large = 80,
}
local KEY_FONT_SIZES = {
    extra_compact = 18, compact = 20, normal = 22, large = 26,
}

-- Until a Tapless keyboard size is chosen, the keyboard follows KOReader's
-- own compact keyboard setting.
function KeyAdapter:keyHeight()
    local size = self.settings:readSetting("tapless_keyboard_size")
    return KEY_HEIGHTS[size]
        or (self.settings:isTrue("keyboard_key_compact") and 48 or 64)
end

-- The key font size, or nil to keep KOReader's own.
function KeyAdapter:keyFontSize()
    local font_setting = self.settings:readSetting(
        "tapless_keyboard_font_size", "auto")
    if font_setting == 18 or font_setting == 22 or font_setting == 26 then
        return font_setting
    end
    return KEY_FONT_SIZES[self.settings:readSetting("tapless_keyboard_size")]
end

-- VirtualKey reads KOReader's global font-size setting during init.
-- Override that read in memory only, then restore it immediately so
-- disabling Tapless leaves the stock keyboard setting untouched.
function KeyAdapter:initWithKeyFontSize(original_init, key, ...)
    local tapless_size = self:keyFontSize()
    if not tapless_size then
        return original_init(key, ...)
    end
    local settings = self.settings
    local original_read_setting = settings.readSetting
    settings.readSetting = function(target, setting, default)
        if setting == "keyboard_key_font_size" then
            return tapless_size
        end
        return original_read_setting(target, setting, default)
    end

    local ok, err = pcall(original_init, key, ...)
    settings.readSetting = original_read_setting

    if not ok then
        error(err)
    end
end

-- Each wrapper receives the method it replaces. Tapless logic runs only in
-- the outermost copy: if another patch later wraps a Tapless wrapper and
-- ensureInstalled() wraps again, the inner copy passes straight through.
function KeyAdapter:wrappers()
    local adapter = self
    return {
        init = function(original)
            return function(key, ...)
                adapter:initWithKeyFontSize(original, key, ...)
                local frame = key[1]
                local center = frame and frame[1]
                local content = center and center[1]
                if key.alt_label and content then
                    local main_container = content[1]
                    local alt_container = content[2]
                    local main_widget = main_container and main_container[1]
                    local alt_widget = alt_container and alt_container[1]
                    if main_widget and main_widget.setText then
                        key.swype_mvp_label_widget = main_widget
                    end
                    if alt_widget and alt_widget.setText then
                        key.swype_mvp_alt_label_widget = alt_widget
                    end
                elseif content and content.setText then
                    key.swype_mvp_label_widget = content
                end
                if adapter:isTextKey(key) then
                    key.swipe_callback = nil
                end
                key.ges_events.MultiswipeKey = {
                    adapter.gesture_range:new{
                        ges = "multiswipe",
                        range = key.dimen,
                    },
                }
                if adapter:isSpaceKey(key) and adapter:spaceCursorEnabled() then
                    key.ges_events.SpaceCursorPan = {
                        adapter.gesture_range:new{
                            ges = "pan",
                            range = function() return key.keyboard.dimen end,
                        },
                    }
                end
            end
        end,

        onSpaceCursorPan = function()
            return function(key, _, ges)
                return adapter:moveSpaceCursor(key, ges)
            end
        end,

        onSwipeKey = function(original)
            return function(key, arg, ges)
                local keyboard = key.keyboard
                if adapter:finishSpaceCursor(keyboard, ges) then
                    return true
                end
                if keyboard and keyboard:isSwypeMvpEnabled() then
                    if adapter:isTextKey(key) then
                        keyboard:onSwypeWordSwipe(arg, ges, key)
                        return true
                    elseif keyboard.swype_mvp_trace then
                        keyboard:_swypeReset()
                    end
                end
                return original(key, arg, ges)
            end
        end,

        onMultiswipeKey = function()
            return function(key, arg, ges)
                local keyboard = key.keyboard
                if keyboard and keyboard:isSwypeMvpEnabled() then
                    if adapter:isTextKey(key) then
                        keyboard:onSwypeWordMultiswipe(arg, ges, key)
                        return true
                    elseif keyboard.swype_mvp_trace then
                        keyboard:_swypeReset()
                    end
                end
                return key:onSwipeKey(arg, ges)
            end
        end,

        onPanReleaseKey = function(original)
            return function(key, arg, ges)
                local keyboard = key.keyboard
                if adapter:finishSpaceCursor(keyboard, ges) then
                    return true
                end
                if keyboard and keyboard:isSwypeMvpEnabled()
                        and keyboard:onSwypeWordPanRelease(arg, ges) then
                    return true
                end
                return original(key, arg, ges)
            end
        end,
    }
end

function KeyAdapter:_guard(name, wrapped, original)
    local active = self.active
    return function(...)
        if active[name] and original then
            return original(...)
        end
        active[name] = true
        local ok, result = pcall(wrapped, ...)
        active[name] = nil
        if not ok then
            error(result, 0)
        end
        return result
    end
end

function KeyAdapter:install(VirtualKey)
    if VirtualKey._tapless_adapter_installed then
        return
    end
    VirtualKey._tapless_adapter_installed = true
    self.VirtualKey = VirtualKey
    self:ensureInstalled()
end

-- Another plugin or user patch may replace these methods after Tapless has
-- loaded. Call this before building keys so letter swipes still reach
-- Tapless first; anything Tapless does not handle falls through to the
-- replacement.
function KeyAdapter:ensureInstalled()
    local VirtualKey = self.VirtualKey
    if not VirtualKey then
        return
    end
    for name, build in pairs(self:wrappers()) do
        local current = rawget(VirtualKey, name)
        if current == nil or current ~= self.installed[name] then
            local original = VirtualKey[name]
            if not OPTIONAL_METHODS[name] then
                assert(original, "Tapless: VirtualKey." .. name .. " missing")
            end
            local wrapped = self:_guard(name, build(original), original)
            VirtualKey[name] = wrapped
            self.installed[name] = wrapped
        end
    end
end

return KeyAdapter
