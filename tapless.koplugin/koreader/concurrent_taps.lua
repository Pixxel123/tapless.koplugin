-- Backport of KOReader's "VirtualKeyboard: preserve concurrent taps"
-- (koreader/koreader#15840, not in v2026.07.x and older releases).
--
-- When a second finger lands before the first one lifts, KOReader combines
-- both contacts into one gesture and drops a keypress. With this, each
-- contact lifting while the keyboard is on top is reported as its own tap.
--
-- Nothing is installed on KOReader versions that already have the feature.

local ConcurrentTaps = {}

local findUpvalue = dofile((debug.getinfo(1, "S").source
    :match("^@(.+)/[^/]+%.lua$") or ".") .. "/find_upvalue.lua")

-- options: input, gesture_detector, ui_manager, geometry, logger,
-- and the widget classes that should receive concurrent taps.
function ConcurrentTaps.install(options)
    local Input = assert(options.input)
    if Input._tapless_concurrent_taps then
        return true
    end
    if Input.allow_concurrent_taps ~= nil then
        return false -- KOReader has this built in
    end
    local Contact = findUpvalue(options.gesture_detector.newContact, "Contact")
    if type(Contact) ~= "table" or type(Contact.tapState) ~= "function" then
        options.logger.warn("Tapless: cannot backport concurrent taps")
        return false
    end
    Input._tapless_concurrent_taps = true
    Input.allow_concurrent_taps = false
    for _, widget_class in ipairs(options.widget_classes) do
        widget_class.allow_concurrent_taps = true
    end

    local Geom = assert(options.geometry)
    local UIManager = assert(options.ui_manager)

    local function wanted(widget)
        return widget ~= nil and widget.allow_concurrent_taps == true
    end

    -- Follow the topmost widget, as UIManager does upstream.
    local original_show = UIManager.show
    function UIManager:show(widget, ...)
        original_show(self, widget, ...)
        if widget and not (self.silent_mode and widget.honor_silent_mode) then
            Input.allow_concurrent_taps = wanted(widget)
        end
    end

    local original_close = UIManager.close
    function UIManager:close(widget, ...)
        original_close(self, widget, ...)
        if widget then
            local top = self._window_stack[#self._window_stack]
            Input.allow_concurrent_taps = top ~= nil and wanted(top.widget)
        end
    end

    local original_tap_state = Contact.tapState
    function Contact:tapState(new_tap)
        local tev = self.current_tev
        if tev.id == -1 and self.buddy_contact and self.down
                and self.ges_dec.input.allow_concurrent_taps then
            -- Emit this contact as a tap. Dropping it clears the buddy link
            -- and leaves the other contact active, so its own lift emits the
            -- second tap.
            self.ges_dec:dropContact(self)
            return {
                ges = "tap",
                pos = Geom:new{ x = tev.x, y = tev.y, w = 0, h = 0 },
                time = tev.timev,
            }
        end
        return original_tap_state(self, new_tap)
    end
    return true
end

return ConcurrentTaps
