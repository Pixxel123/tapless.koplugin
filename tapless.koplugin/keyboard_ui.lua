local KeyboardUI = {}
KeyboardUI.__index = KeyboardUI

function KeyboardUI:new(options)
    return setmetatable({
        candidate_row = assert(options.candidate_row),
        dictionary_manager = assert(options.dictionary_manager),
        plugin_dir = assert(options.plugin_dir),
        horizontal_group = assert(options.horizontal_group),
        virtual_key = assert(options.virtual_key),
        ui_manager = assert(options.ui_manager),
        gesture_range = assert(options.gesture_range),
        screen = assert(options.screen),
    }, self)
end

function KeyboardUI:createCandidateRow(keyboard, options)
    return self.candidate_row:create{
        HorizontalGroup = self.horizontal_group,
        VirtualKey = self.virtual_key,
        keyboard = keyboard,
        width = options.width,
        height = options.height,
        key_padding = options.key_padding,
        padding = options.padding,
        horizontal_padding = options.horizontal_padding,
        candidates = keyboard.swype_mvp_session:getCandidates(),
        dictionary_label = keyboard:_swypeDictionaryLabel(),
        on_open_manager = function()
            self.dictionary_manager:open(keyboard, self.plugin_dir)
            keyboard:onClose()
        end,
        on_toggle_dictionary = function()
            keyboard:_swypeToggleDictionary()
        end,
        on_select_candidate = function(index)
            local candidates =
                keyboard.swype_mvp_session:getCandidates() or {}
            local candidate = candidates[index]
            if candidate then
                keyboard:_swypeSelectCandidate(candidate)
            end
        end,
    }
end

function KeyboardUI:registerGestureRanges(keyboard)
    keyboard.ges_events.SwypeWordPan = {
        self.gesture_range:new{
            ges = "pan",
            range = function() return keyboard.dimen end,
            rate = 60,
        },
    }
    keyboard.ges_events.SwypeWordPanRelease = {
        self.gesture_range:new{
            ges = "pan_release",
            range = function() return self.screen:getSize() end,
        },
    }
    keyboard.ges_events.SwypeWordSwipe = {
        self.gesture_range:new{
            ges = "swipe",
            range = function() return self.screen:getSize() end,
        },
    }
    keyboard.ges_events.SwypeWordMultiswipe = {
        self.gesture_range:new{
            ges = "multiswipe",
            range = function() return self.screen:getSize() end,
        },
    }
end

function KeyboardUI:refreshCandidateRow(keyboard, refresh_type, only_index)
    if not keyboard.swype_mvp_candidate_keys then
        keyboard:addKeys()
    end
    self.candidate_row:refresh{
        keys = keyboard.swype_mvp_candidate_keys,
        candidates = keyboard.swype_mvp_session:getCandidates(),
        dictionary_label = keyboard:_swypeDictionaryLabel(),
        refresh_type = refresh_type or "ui",
        only_index = only_index,
        UIManager = self.ui_manager,
    }
end

return KeyboardUI
