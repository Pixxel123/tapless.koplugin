local InputController = {}
InputController.__index = InputController
local Utf8Proc = require("ffi/utf8proc")

InputController.DOUBLE_SPACE_SETTING = "tapless_double_space_period"

function InputController:new(context_model, normalization, logger, text_case,
        personal_dictionary, dictionary_store, ui_manager, settings,
        blocked_words)
    return setmetatable({
        blocked_words = blocked_words,
        settings = assert(settings),
        context_model = assert(context_model),
        normalization = assert(normalization),
        logger = assert(logger),
        text_case = assert(text_case),
        personal_dictionary = assert(personal_dictionary),
        dictionary_store = assert(dictionary_store),
        ui_manager = assert(ui_manager),
    }, self)
end

function InputController:_wordAtEnd(text, profile, skip_trailing)
    local chars = self.normalization:splitChars(text or "")
    local index = #chars
    if skip_trailing then
        while index > 0
                and not self.normalization:normalizeChar(chars[index], profile) do
            index = index - 1
        end
    elseif index == 0
            or not self.normalization:normalizeChar(chars[index], profile) then
        return
    end
    local last = index
    while index > 0
            and self.normalization:normalizeChar(chars[index], profile) do
        index = index - 1
    end
    if last - index < 2 then
        return
    end
    local word = table.concat(chars, "", index + 1, last)
    return self.personal_dictionary:prepareWord(word, profile) and word or nil
end

function InputController:_setPersonalOffer(keyboard, word)
    local session = keyboard.swype_mvp_session
    local current = session:getPersonalOffer()
    local language = keyboard.swype_mvp_dictionary or "en"
    local profile = keyboard.swype_mvp_normalization_profile
    local prepared, signature = self.personal_dictionary:prepareWord(
        word, profile)
    local added = prepared and self.personal_dictionary:contains(
        language, prepared, profile) or false
    if prepared and not added
            and self.dictionary_store:containsWord(
                signature, prepared, language) then
        word = nil
    end
    if not current and not word then
        return
    end
    if current and current.word == word and current.added == added then
        return
    end
    session:setPersonalOffer(word and { word = word, added = added } or nil)
    keyboard:_swypeRefreshCandidateRow()
end

function InputController:_cancelPersonalOfferTimer(keyboard)
    keyboard.swype_mvp_personal_offer_generation =
        (keyboard.swype_mvp_personal_offer_generation or 0) + 1
end

function InputController:_schedulePersonalOffer(keyboard, completed)
    self:_cancelPersonalOfferTimer(keyboard)
    local generation = keyboard.swype_mvp_personal_offer_generation
    local function show()
        if keyboard.swype_mvp_closed
                or keyboard.swype_mvp_personal_offer_generation ~= generation
                or keyboard.swype_mvp_session:getCandidates() then
            return
        end
        local text = keyboard.inputbox and keyboard.inputbox.getText
            and keyboard.inputbox:getText() or ""
        self:_setPersonalOffer(keyboard, self:_wordAtEnd(
            text, keyboard.swype_mvp_normalization_profile, completed))
    end
    self.ui_manager:scheduleIn(completed and 0.01 or 0.45, show)
end

function InputController:_afterManualEdit(keyboard, completed)
    if not completed then
        local had_offer = keyboard.swype_mvp_session:clearPersonalOffer()
        if had_offer then
            keyboard:_swypeRefreshCandidateRow()
        end
    end
    self:_schedulePersonalOffer(keyboard, completed)
end

function InputController:_clearPersonalOffer(keyboard)
    self:_cancelPersonalOfferTimer(keyboard)
    if keyboard.swype_mvp_session:clearPersonalOffer() then
        keyboard:_swypeRefreshCandidateRow()
    end
end

function InputController:addPersonalWord(keyboard)
    local offer = keyboard.swype_mvp_session:getPersonalOffer()
    if not offer or offer.added then
        return false
    end
    local ok, err = self.personal_dictionary:add(
        keyboard.swype_mvp_dictionary or "en", offer.word,
        keyboard.swype_mvp_normalization_profile)
    if not ok then
        self.logger.warn("Tapless: cannot add personal word", err)
        return false
    end
    if self.blocked_words then
        self.blocked_words:remove(
            keyboard.swype_mvp_dictionary or "en", offer.word)
    end
    offer.added = true
    keyboard:_swypeRefreshCandidateRow()
    return true
end

function InputController:applyCandidateCase(keyboard, candidates)
    local mode
    if keyboard.shiftmode and not keyboard.symbolmode then
        mode = keyboard.release_shift and "title" or "upper"
    end
    local language = keyboard.swype_mvp_dictionary
    for _, candidate in ipairs(candidates or {}) do
        candidate.output_word = self.text_case:apply(
            candidate.word, mode, language)
    end
end

function InputController:releaseOneShotShift(keyboard)
    if keyboard.shiftmode and not keyboard.symbolmode
            and keyboard.release_shift and keyboard.setLayer then
        keyboard:setLayer("Shift")
    end
end

function InputController:deleteText(keyboard, text)
    for _ = 1, #self.normalization:splitChars(text or "") do
        keyboard.inputbox:delChar()
    end
end

function InputController:getPreviousWord(keyboard)
    if not keyboard.inputbox or not keyboard.inputbox.getText then
        return
    end
    local text = keyboard.inputbox:getText() or ""
    local word = text:match("([^%s%p%d]+)%s*$")
    if word and #word > 0 then
        return Utf8Proc.lowercase_dumb(word)
    end
end

function InputController:contextBonus(previous_word, word)
    return self.context_model:bonus(previous_word, word)
end

function InputController:learnContext(previous_word, word)
    self.context_model:learn(previous_word, word)
end

function InputController:commitPendingContext(keyboard)
    self.context_model:commit(keyboard.swype_mvp_session:getLastInsert())
end

function InputController:saveContext()
    self.context_model:save()
end

function InputController:clearCandidateState(keyboard, keep_debug)
    self:_cancelPersonalOfferTimer(keyboard)
    keyboard.swype_mvp_session:clear(keep_debug)
end

function InputController:clearCandidateRow(keyboard, refresh_type)
    self:clearCandidateState(keyboard)
    keyboard:_swypeRefreshCandidateRow(refresh_type)
end

function InputController:rejectLastInsert(keyboard)
    local rejection = keyboard.swype_mvp_session:rejection()
    if rejection.text then
        self.logger.dbg("swype mvp rejected", rejection.signature)
        self:deleteText(keyboard, rejection.text)
        keyboard:_swypeReset()
        self:clearCandidateState(keyboard)
        keyboard:_swypeRefreshCandidateRow()
        return true
    end
    if rejection.handled then
        keyboard:_swypeReset()
        self:clearCandidateRow(keyboard)
        return true
    end
    return false
end

function InputController:selectCandidate(keyboard, candidate)
    local selection = keyboard.swype_mvp_session:selection(candidate)
    if not selection then
        self:clearCandidateRow(keyboard)
        return
    end
    if selection.delete_text then
        self:deleteText(keyboard, selection.delete_text)
    end
    self.logger.dbg(
        "swype mvp selected", candidate.signature, "=>", candidate.word)
    self:learnContext(selection.pending.previous_word, candidate.word)
    selection.pending.context_committed = true
    keyboard.inputbox:addChars(selection.replacement)
    self:_markSpace(keyboard)
    self:clearCandidateState(keyboard)
    keyboard:_swypeRefreshCandidateRow()
end

-- Never suggests the word again in this language. The word a swipe just
-- typed is replaced by the next suggestion; any other suggestion is taken
-- off the suggestion row.
function InputController:blockCandidate(keyboard, candidate)
    if not self.blocked_words or not candidate then
        return false
    end
    local ok, err = self.blocked_words:add(
        keyboard.swype_mvp_dictionary or "en", candidate.word)
    if ok == nil then
        self.logger.warn("Tapless: cannot block word", err)
        return false
    end
    local session = keyboard.swype_mvp_session
    local remaining = session:removeCandidate(candidate)
    local last_insert = session:getLastInsert()
    if last_insert and last_insert.word == candidate.word then
        if remaining[1] then
            self:selectCandidate(keyboard, remaining[1])
        else
            self:rejectLastInsert(keyboard)
        end
    else
        keyboard:_swypeRefreshCandidateRow()
    end
    return true
end

function InputController:insertBestAndShowCandidates(
        keyboard, signature, candidates, previous_word)
    if not candidates or #candidates == 0 then
        self.logger.dbg("swype mvp no confident candidate", signature)
        keyboard.swype_mvp_session:recordNoCandidate(signature)
        keyboard:_swypeRefreshCandidateRow()
        return false
    end
    self:applyCandidateCase(keyboard, candidates)
    local inserted = keyboard.swype_mvp_session:recordInsert(
        signature, candidates, previous_word)
    self.logger.dbg("swype mvp best", signature, "=>", candidates[1].word)
    keyboard.inputbox:addChars(inserted)
    self:_markSpace(keyboard)
    keyboard:_swypeRefreshCandidateRow()
    self:releaseOneShotShift(keyboard)
    return true
end

function InputController:tapTraceKey(keyboard, trace_info)
    local point = trace_info.letter_points and trace_info.letter_points[1]
    local _, key = keyboard:_swypeKeyAt(point)
    if not key or not key.onTapSelect then
        return false
    end
    self.logger.dbg("swype mvp short trace typed as tap", key.key)
    key:onTapSelect()
    return true
end

function InputController:finalizeSignature(keyboard, signature, trace_info)
    if not signature or #signature == 0 then
        return false
    end
    if #signature < 2 then
        -- A finger that drifted while tapping only crosses one key. Type
        -- that key as a tap instead of dropping it, but only once the finger
        -- is lifted, not when a paused trace times out.
        if trace_info and trace_info.released
                and self:tapTraceKey(keyboard, trace_info) then
            return true
        end
        keyboard.swype_mvp_session:recordShortSignature(signature)
        keyboard:_swypeRefreshCandidateRow()
        return true
    end
    local candidates = keyboard:_swypePickCandidates(
 signature, 4, trace_info)
    self:insertBestAndShowCandidates(
        keyboard, signature, candidates,
        trace_info and trace_info.previous_word)
    return true
end

-- Remember where a space typed by the keyboard ended, whether tapped or
-- added after a swiped word, so a second space right after it can become
-- a period.
function InputController:_markSpace(keyboard)
    keyboard.swype_mvp_space_charpos = keyboard.inputbox.charpos
end

function InputController:_takeDoubleSpace(keyboard, key)
    local charpos = keyboard.swype_mvp_space_charpos
    keyboard.swype_mvp_space_charpos = nil
    if key ~= " " or not charpos
            or not self.settings:isTrue(self.DOUBLE_SPACE_SETTING)
            -- Input method layouts (Chinese, Japanese, Korean, Vietnamese)
            -- use space themselves and have their own punctuation.
            or keyboard.uwrap_func then
        return false
    end
    local inputbox = keyboard.inputbox
    if inputbox.charpos ~= charpos or inputbox:getChar(-1) ~= " " then
        return false
    end
    local previous = inputbox:getChar(-2)
    return previous ~= nil and not previous:match("^[%s%p]$")
end

function InputController:addChar(keyboard, key, keep_swype_candidates)
    local period = self:_takeDoubleSpace(keyboard, key)
    self:commitPendingContext(keyboard)
    if period then
        -- Drop the swiped word's undo state: backspace must not remove
        -- "word " from text that now ends in "word. ".
        keep_swype_candidates = false
        self:clearCandidateState(keyboard)
        keyboard.inputbox:delChar()
        key = ". "
    end
    if not keep_swype_candidates
            and keyboard.swype_mvp_session:getCandidates() then
        self:clearCandidateRow(keyboard)
    end
    self.logger.dbg("add char", key)
    keyboard.inputbox:addChars(key)
    if key == " " then
        self:_markSpace(keyboard)
    end
    local chars = self.normalization:splitChars(key or "")
    local last = chars[#chars]
    if last and self.normalization:normalizeChar(
            last, keyboard.swype_mvp_normalization_profile) then
        self:_afterManualEdit(keyboard, false)
    elseif last and (last:match("^%s$") or last:match("^%p$")) then
        self:_afterManualEdit(keyboard, true)
    else
        self:_clearPersonalOffer(keyboard)
    end
end

function InputController:delChar(keyboard)
    keyboard.swype_mvp_space_charpos = nil
    if self:rejectLastInsert(keyboard) then
        return
    end
    self.logger.dbg("delete char")
    keyboard.inputbox:delChar()
    self:_afterManualEdit(keyboard, false)
end

return InputController
