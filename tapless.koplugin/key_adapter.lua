local KeyAdapter = {}
KeyAdapter.__index = KeyAdapter

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
            end
        end,

        onSwipeKey = function(original)
            return function(key, arg, ges)
                local keyboard = key.keyboard
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
            if name ~= "onMultiswipeKey" then
                assert(original, "Tapless: VirtualKey." .. name .. " missing")
            end
            local wrapped = self:_guard(name, build(original), original)
            VirtualKey[name] = wrapped
            self.installed[name] = wrapped
        end
    end
end

return KeyAdapter
