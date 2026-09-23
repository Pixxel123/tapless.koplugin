local KeyboardUI = {
    -- The suggestion row's words change with quick partial refreshes,
    -- which leave faint ghosts of earlier words on e-ink. After this many
    -- changes the whole row is refreshed once with a flash.
    ROW_CLEANUP_EVERY = 6,
}
KeyboardUI.__index = KeyboardUI

function KeyboardUI:new(options)
    return setmetatable({
        candidate_row = assert(options.candidate_row),
        dictionary_manager = assert(options.dictionary_manager),
        personal_dictionary = assert(options.personal_dictionary),
        confirm_box = assert(options.confirm_box),
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
        personal_offer = keyboard.swype_mvp_session:getPersonalOffer(),
        on_select_candidate = function(index)
            local candidates =
                keyboard.swype_mvp_session:getCandidates() or {}
            local candidate = candidates[index]
            if candidate then
                keyboard:_swypeSelectCandidate(candidate)
            end
        end,
        get_personal_offer = function()
            return keyboard.swype_mvp_session:getPersonalOffer()
        end,
        on_add_personal_word = function()
            keyboard:_swypeAddPersonalWord()
        end,
        on_hold_candidate = function(index)
            local candidates =
                keyboard.swype_mvp_session:getCandidates() or {}
            local candidate = candidates[index]
            if not candidate then
                return false
            end
            self.ui_manager:show(self.confirm_box:new{
                text = "Never suggest \""
                    .. (candidate.output_word or candidate.word) .. "\"?",
                ok_text = "Block",
                ok_callback = function()
                    keyboard:_swypeBlockCandidate(candidate)
                end,
            })
            return true
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
    local changed = self.candidate_row:refresh{
        keys = keyboard.swype_mvp_candidate_keys,
        candidates = keyboard.swype_mvp_session:getCandidates(),
        personal_offer = keyboard.swype_mvp_session:getPersonalOffer(),
        refresh_type = refresh_type or "ui",
        only_index = only_index,
        UIManager = self.ui_manager,
    }
    if not changed then
        return
    end
    keyboard.swype_mvp_row_changes = (keyboard.swype_mvp_row_changes or 0) + 1
    if keyboard.swype_mvp_row_changes >= self.ROW_CLEANUP_EVERY then
        keyboard.swype_mvp_row_changes = 0
        local region
        for _, key in ipairs(keyboard.swype_mvp_candidate_keys) do
            local dimen = key[1] and key[1].dimen
            if dimen then
                region = region and region:combine(dimen) or dimen
            end
        end
        if region then
            self.ui_manager:setDirty(nil, "flashui", region)
        end
    end
end

function KeyboardUI:openDictionaryManager(keyboard)
 self.dictionary_manager:open(
 keyboard, self.plugin_dir, self.personal_dictionary)
 keyboard:onClose()
end

function KeyboardUI:refreshLanguageIndicator(keyboard, refresh_type)
 local key = keyboard.swype_mvp_language_key
 if not key then
 return
 end

 local label = keyboard:_swypeDictionaryLabel()
 key.alt_label = label

 if key.swype_mvp_alt_label_widget then
 key.swype_mvp_alt_label_widget:setText(label)
 end

 if key[1] and key[1].dimen then
 self.ui_manager:widgetRepaint(
 key[1], key[1].dimen.x, key[1].dimen.y)
 self.ui_manager:setDirty(
 nil, refresh_type or "ui", key[1].dimen)
 end
end

return KeyboardUI
