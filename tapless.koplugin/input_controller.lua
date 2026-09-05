local InputController = {}
InputController.__index = InputController

function InputController:new(context_model, normalization, logger)
    return setmetatable({
        context_model = assert(context_model),
        normalization = assert(normalization),
        logger = assert(logger),
    }, self)
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
        return string.lower(word)
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
    self:clearCandidateState(keyboard)
    keyboard:_swypeRefreshCandidateRow()
end

function InputController:insertBestAndShowCandidates(
        keyboard, signature, candidates, previous_word)
    if not candidates or #candidates == 0 then
        self.logger.dbg("swype mvp no confident candidate", signature)
        keyboard.swype_mvp_session:recordNoCandidate(signature)
        keyboard:_swypeRefreshCandidateRow()
        return false
    end
    local inserted = candidates[1].word .. " "
    self.logger.dbg("swype mvp best", signature, "=>", candidates[1].word)
    keyboard.inputbox:addChars(inserted)
    keyboard.swype_mvp_session:recordInsert(
        signature, candidates, previous_word)
    keyboard:_swypeRefreshCandidateRow()
end

function InputController:finalizeSignature(keyboard, signature, trace_info)
    if not signature or #signature == 0 then
        return false
    end
    if #signature < 2 then
        keyboard.swype_mvp_session:recordShortSignature(signature)
        keyboard:_swypeRefreshCandidateRow()
        return true
    end
    local candidates = keyboard:_swypePickCandidates(
        signature, 3, trace_info)
    self:insertBestAndShowCandidates(
        keyboard, signature, candidates,
        trace_info and trace_info.previous_word)
    return true
end

function InputController:addChar(keyboard, key, keep_swype_candidates)
    self:commitPendingContext(keyboard)
    if not keep_swype_candidates
            and keyboard.swype_mvp_session:getCandidates() then
        self:clearCandidateRow(keyboard)
    end
    self.logger.dbg("add char", key)
    keyboard.inputbox:addChars(key)
end

function InputController:delChar(keyboard)
    if self:rejectLastInsert(keyboard) then
        return
    end
    self.logger.dbg("delete char")
    keyboard.inputbox:delChar()
end

return InputController
