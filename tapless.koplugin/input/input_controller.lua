local InputController = {}
InputController.__index = InputController
local Utf8Proc = require("ffi/utf8proc")

InputController.DOUBLE_SPACE_SETTING = "tapless_double_space_period"
-- Suggest words that complete a word being tapped out. On unless turned
-- off.
InputController.COMPLETION_SETTING = "tapless_tap_completions"
-- The word lists completions need are read a slice at a time: this many
-- entries or milliseconds per slice, a slice every WARM_STEP_DELAY
-- seconds, so typing never waits for them.
InputController.WARM_STEP_DELAY = 0.02
InputController.WARM_BATCH = 96
InputController.WARM_WORK_MS = 3

-- What a word picked from the suggestions counts for in the usage model. A
-- word swiped and left in the text counts for one.
InputController.PICK_USES = 2

-- usage_model, which counts the words the user keeps, is optional.
function InputController:new(context_model, normalization, logger, text_case,
        personal_dictionary, dictionary_store, ui_manager, settings,
        blocked_words, time_api, usage_model)
    return setmetatable({
        blocked_words = blocked_words,
        time = time_api,
        usage_model = usage_model,
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
    -- A dictionary word with the same letters needs no adding: "dont" has
    -- "don't".
    if prepared and not added
            and self.dictionary_store:hasLetters(signature, language) then
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
        local session = keyboard.swype_mvp_session
        if keyboard.swype_mvp_closed
                or keyboard.swype_mvp_personal_offer_generation ~= generation
                or (session:getCandidates()
                    and not session:getCompletion()) then
            return
        end
        -- Mid-word, words completing it come first; the offer to add the
        -- word to personal words shows when none do.
        if not completed and self:_showCompletions(keyboard) then
            return
        end
        local had_completions = session:clearCompletions()
        local text = keyboard.inputbox and keyboard.inputbox.getText
            and keyboard.inputbox:getText() or ""
        self:_setPersonalOffer(keyboard, self:_wordAtEnd(
            text, keyboard.swype_mvp_normalization_profile, completed))
        if had_completions then
            keyboard:_swypeRefreshCandidateRow()
        end
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

local function isApostrophe(char)
    return char == "'" or char == "’"
end

-- The word a next word is taken to follow: the last run of letters before
-- any trailing spaces, with an apostrophe inside it ("don't"), lowercased.
-- Nothing when punctuation or a digit ends the text.
local function lastWord(text)
    local word = text:match("([^%s%p%d]+'[^%s%p%d]+)%s*$")
        or text:match("([^%s%p%d]+’[^%s%p%d]+)%s*$")
        or text:match("([^%s%p%d]+)%s*$")
    return word and (Utf8Proc.lowercase_dumb(word):gsub("’", "'")) or nil
end

-- Characters that join a word to the next letters without being part of
-- either: "well-known", "3rd". Letters after one are no word of their own.
local function joinsWord(char)
    return char == "-" or char:match("^%d$") ~= nil
end

-- How much text before the cursor is read to find the word being typed
-- and the one before it.
local CURSOR_CONTEXT = 80
local MAX_WORD_LETTERS = 32

function InputController:getPreviousWord(keyboard)
    if not keyboard.inputbox or not keyboard.inputbox.getText then
        return
    end
    return lastWord(keyboard.inputbox:getText() or "")
end

-- What word earns for following previous_word: learned from the user's
-- own text, and from the dictionary's word-pair table.
function InputController:contextBonus(previous_word, word, dictionary)
    return self.context_model:bonus(previous_word, word,
        self.dictionary_store:pairBonus(previous_word, word, dictionary))
end

function InputController:learnContext(previous_word, word)
    self.context_model:learn(previous_word, word)
end

function InputController:wordUses(word)
    return self.usage_model and self.usage_model:uses(word) or 0
end

-- Completions and learning tapped words are for alphabetic layouts: on
-- input method layouts (Chinese, Japanese, Korean, Vietnamese) the letters
-- tapped are still being composed into other characters.
function InputController:_completionsEnabled(keyboard)
    return not keyboard.uwrap_func
        and self.settings:nilOrTrue(self.COMPLETION_SETTING)
end

-- The word the cursor ends, as typed, apostrophes included ("don't",
-- "don'"), and the word before it as swipes see one (lastWord), when only
-- spaces lie between them. Nothing when the cursor is not at the end of a
-- word, or the word is joined to the text before it.
function InputController:_wordAtCursor(keyboard)
    local inputbox = keyboard.inputbox
    -- KOReader releases without InputText:getChar cannot say.
    if not inputbox.getChar then
        return
    end
    local profile = keyboard.swype_mvp_normalization_profile
    local function isLetter(char)
        return char ~= nil
            and self.normalization:normalizeChar(char, profile) ~= nil
    end
    local after = inputbox:getChar(0)
    if isLetter(after) or (after and isApostrophe(after)
            and isLetter(inputbox:getChar(1))) then
        return
    end
    local before = {}
    for offset = -1, -CURSOR_CONTEXT, -1 do
        local char = inputbox:getChar(offset)
        if not char then
            break
        end
        table.insert(before, 1, char)
    end
    local start = #before + 1
    while start > 1 and (isLetter(before[start - 1])
            or isApostrophe(before[start - 1])) do
        start = start - 1
    end
    -- A word starts with a letter: a quote before it is not part of it.
    while start <= #before and isApostrophe(before[start]) do
        start = start + 1
    end
    local length = #before - start + 1
    if length == 0 or length > MAX_WORD_LETTERS
            or (before[start - 1] and joinsWord(before[start - 1])) then
        return
    end
    local rest = table.concat(before, "", 1, start - 1)
    return table.concat(before, "", start),
        rest:match("%s$") and lastWord(rest) or nil
end

-- Gives completions the capitals typed: "Th" completes to "The", "TH" to
-- "THE".
function InputController:_applyTypedCase(keyboard, candidates, typed)
    local chars = self.normalization:splitChars(typed)
    local capitals = 0
    for _, char in ipairs(chars) do
        if Utf8Proc.lowercase_dumb(char) ~= char then
            capitals = capitals + 1
        end
    end
    local mode
    if #chars > 1 and capitals == #chars then
        mode = "upper"
    elseif chars[1] and Utf8Proc.lowercase_dumb(chars[1]) ~= chars[1] then
        mode = "title"
    end
    for _, candidate in ipairs(candidates) do
        candidate.output_word = self.text_case:apply(
            candidate.word, mode, keyboard.swype_mvp_dictionary)
    end
end

-- Shows words completing the word being tapped out; false when there are
-- none to show.
function InputController:_showCompletions(keyboard)
    if not self:_completionsEnabled(keyboard) then
        return false
    end
    local typed, previous_word = self:_wordAtCursor(keyboard)
    if not typed then
        return false
    end
    local prefix = self.normalization:normalizeText(typed,
        keyboard.swype_mvp_normalization_profile)
    local candidates = keyboard:_swypeCompleteWord(prefix,
        Utf8Proc.lowercase_dumb(typed), previous_word, 4)
    if #candidates == 0 then
        return false
    end
    self:_applyTypedCase(keyboard, candidates, typed)
    keyboard.swype_mvp_session:setCompletions(candidates, {
        inputbox = keyboard.inputbox,
        prefix = prefix,
    })
    keyboard:_swypeRefreshCandidateRow()
    return true
end

-- Finishes the word being tapped out with a completion. The row may be a
-- few letters behind the text: the word at the cursor must still be the
-- one the completions were found for, and the completion must still fit
-- it, or nothing is typed.
function InputController:_selectCompletion(keyboard, candidate, completion)
    local typed, previous_word = self:_wordAtCursor(keyboard)
    local prefix = typed and self.normalization:normalizeText(typed,
        keyboard.swype_mvp_normalization_profile) or ""
    if not typed or completion.inputbox ~= keyboard.inputbox
            or prefix:sub(1, #completion.prefix) ~= completion.prefix
            or (candidate.signature or ""):sub(1, #prefix) ~= prefix then
        self:clearCandidateRow(keyboard)
        return
    end
    self:_applyTypedCase(keyboard, { candidate }, typed)
    self:deleteText(keyboard, typed)
    self.logger.dbg("swype mvp completed", typed, "=>", candidate.word)
    self:learnContext(previous_word, candidate.word)
    if self.usage_model then
        self.usage_model:learn(candidate.word, self.PICK_USES)
    end
    keyboard.inputbox:addChars(candidate.output_word or candidate.word)
    keyboard.swype_mvp_tapped_word = nil
    self:_markPendingSpace(keyboard)
    self:clearCandidateState(keyboard)
    keyboard:_swypeRefreshCandidateRow()
end

-- A word tapped out letter by letter and ended with a space or
-- punctuation is learned like a swiped word left in the text, when it is
-- a dictionary or personal word, so typos are not. Looking it up may read
-- a word list from disk, so that waits until the key is handled.
function InputController:_learnTappedWord(keyboard)
    if keyboard.uwrap_func then
        return
    end
    local typed, previous_word = self:_wordAtCursor(keyboard)
    if not typed then
        return
    end
    local profile = keyboard.swype_mvp_normalization_profile
    local language = keyboard.swype_mvp_dictionary or "en"
    local lowered = Utf8Proc.lowercase_dumb(typed):gsub("’", "'")
    local signature = self.normalization:normalizeText(lowered, profile)
    self.ui_manager:scheduleIn(0, function()
        -- The dictionary's own spelling: "i'm" is learned as "I'm".
        local word = self.dictionary_store:findWord(signature, lowered,
            language)
        if not word then
            local personal = self.personal_dictionary
            local prepared = personal:prepareWord(typed, profile)
            if not (prepared
                    and personal:contains(language, prepared, profile)) then
                return
            end
            word = prepared
        end
        self.logger.dbg("swype mvp learned tapped word", word)
        self:learnContext(previous_word, word)
        if self.usage_model then
            self.usage_model:learn(word, 1)
        end
    end)
end

-- Reads the word lists for words starting with first in small slices, a
-- few milliseconds each, so completions can look beyond the most common
-- words without typing waiting for the disk. Waits while a swipe is being
-- drawn, and stops if the keyboard closes or changes language.
function InputController:_warmCompletionLists(keyboard, first)
    if not self:_completionsEnabled(keyboard) then
        return
    end
    local store = self.dictionary_store
    keyboard.swype_mvp_completion_warm =
        (keyboard.swype_mvp_completion_warm or 0) + 1
    local generation = keyboard.swype_mvp_completion_warm
    local dictionary = keyboard.swype_mvp_dictionary or "en"
    local function step()
        if keyboard.swype_mvp_closed
                or keyboard.swype_mvp_completion_warm ~= generation
                or (keyboard.swype_mvp_dictionary or "en") ~= dictionary then
            return
        end
        if keyboard.swype_mvp_trace then
            self.ui_manager:scheduleIn(self.WARM_STEP_DELAY * 4, step)
            return
        end
        for code = string.byte("a"), string.byte("z") do
            local last = string.char(code)
            local loaded = store:isBucketLoaded(dictionary, first .. last)
            -- Also keeps a list a swipe's prefetch read, should that
            -- prefetch be cancelled.
            store:loadBucketSlice(first, last, dictionary,
                self.WARM_BATCH, self.WARM_WORK_MS)
            if not loaded then
                self.ui_manager:scheduleIn(self.WARM_STEP_DELAY, step)
                return
            end
        end
    end
    self.ui_manager:scheduleIn(self.WARM_STEP_DELAY, step)
end

-- The last swiped word is kept once something else happens: it is learned
-- as following the word before it, and counted as used.
function InputController:commitPendingContext(keyboard)
    local pending = keyboard.swype_mvp_session:getLastInsert()
    self.context_model:commit(pending)
    if self.usage_model then
        self.usage_model:commit(pending)
    end
end

function InputController:saveContext()
    self.context_model:save()
    if self.usage_model then
        self.usage_model:save()
    end
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

-- uses is what the word counts for: a pick by default, less when the user
-- did not choose it.
function InputController:selectCandidate(keyboard, candidate, uses)
    local session = keyboard.swype_mvp_session
    local completion = session:getCompletion()
    if completion then
        return self:_selectCompletion(keyboard, candidate, completion)
    end
    local selection = session:selection(candidate)
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
    if self.usage_model then
        self.usage_model:learn(candidate.word, uses or self.PICK_USES)
        selection.pending.usage_committed = true
    end
    keyboard.inputbox:addChars(selection.replacement)
    self:_markPendingSpace(keyboard)
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
            -- The user did not choose the replacement, only refused the word.
            self:selectCandidate(keyboard, remaining[1], 1)
        else
            self:rejectLastInsert(keyboard)
        end
    else
        keyboard:_swypeRefreshCandidateRow()
    end
    return true
end

-- Punctuation that is followed by a space, so a word after it still gets
-- one.
local SPACED_PUNCTUATION = {
    ["."] = true, [","] = true, ["!"] = true, ["?"] = true,
    [":"] = true, [";"] = true, [")"] = true,
}

-- True when a swiped word would land right after the end of a word with
-- no pending space to separate them: a tapped word never marks one, and
-- a stray character or an extra backspace can use one up.
function InputController:_gluedToPreviousWord(keyboard)
    local inputbox = keyboard.inputbox
    if not inputbox.getChar then
        return false
    end
    local profile = keyboard.swype_mvp_normalization_profile
    local last = inputbox:getChar(-1)
    if not last then
        return false
    end
    local next_char = inputbox:getChar(0)
    if next_char and (self.normalization:normalizeChar(next_char, profile)
                ~= nil or next_char:match("^%d$") ~= nil) then
        -- The cursor is inside a word (after a space-cursor slide, say);
        -- a space in front would not make a word boundary there either.
        return false
    end
    return SPACED_PUNCTUATION[last] == true
        or self.normalization:normalizeChar(last, profile) ~= nil
        or last:match("^%d$") ~= nil
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
    -- The swiped word is learned once it is kept, not as a tapped word.
    keyboard.swype_mvp_tapped_word = nil
    local inserted = keyboard.swype_mvp_session:recordInsert(
        signature, candidates, previous_word)
    self.logger.dbg("swype mvp best", signature, "=>", candidates[1].word)
    local pending_space = self:_takePendingSpace(keyboard)
    if pending_space or self:_gluedToPreviousWord(keyboard) then
        keyboard.inputbox:addChars(" ")
    end
    keyboard.inputbox:addChars(inserted)
    self:_markPendingSpace(keyboard)
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

-- Right after a letter is tapped, a slide shorter than most of a key is a
-- tap whose finger slipped onto the next key, not a swipe.
local TAP_COOLDOWN_MS = 500
local SLIP_KEY_FRACTION = 0.6

function InputController:_slippedTap(keyboard, trace_info)
    local tapped = keyboard.swype_mvp_last_letter_tap
    local points = trace_info and trace_info.points
    local first = points and points[1]
    if not (self.time and tapped and trace_info.released and first
            and first.time) then
        return false
    end
    if first.time - tapped > self.time.ms(TAP_COOLDOWN_MS) then
        return false
    end
    local _, key = keyboard:_swypeKeyAt(first)
    local width = key and key.dimen and key.dimen.w
    if not width then
        return false
    end
    local length = 0
    for index = 2, #points do
        local dx = points[index].x - points[index - 1].x
        local dy = points[index].y - points[index - 1].y
        length = length + math.sqrt(dx * dx + dy * dy)
    end
    return length < width * SLIP_KEY_FRACTION
end

function InputController:finalizeSignature(keyboard, signature, trace_info)
    if not signature or #signature == 0 then
        return false
    end
    if #signature < 2 then
        -- A finger that drifted while tapping only crosses one key. Type
        -- that key as a tap instead of dropping it, but only once the finger
        -- is lifted, not when a paused trace times out.
        if trace_info and trace_info.released then
            -- A swipe that began on a number key counts as starting on the
            -- letter below, yet may cross no other letter. That is a tap or
            -- a flick on the number key itself, and KOReader knows what
            -- it types, alternate characters included.
            local first = trace_info.letter_points
                and trace_info.letter_points[1]
            if first and not keyboard:_swypeKeyAt(first) then
                return false
            end
            if self:tapTraceKey(keyboard, trace_info) then
                return true
            end
        end
        keyboard.swype_mvp_session:recordShortSignature(signature)
        keyboard:_swypeRefreshCandidateRow()
        return true
    end
    if self:_slippedTap(keyboard, trace_info)
            and self:tapTraceKey(keyboard, trace_info) then
        return true
    end
    local candidates = keyboard:_swypePickCandidates(
        signature, 4, trace_info)
    self:insertBestAndShowCandidates(
        keyboard, signature, candidates,
        trace_info and trace_info.previous_word)
    return true
end

-- Remember where a tapped space ended, so a second space right after it
-- can become a period.
function InputController:_markSpace(keyboard)
    keyboard.swype_mvp_space_charpos = keyboard.inputbox.charpos
end

-- A swiped word is followed by a space only once something else is typed:
-- the next swiped or tapped word gets one, punctuation does not.
function InputController:_markPendingSpace(keyboard)
    keyboard.swype_mvp_pending_space = {
        inputbox = keyboard.inputbox,
        charpos = keyboard.inputbox.charpos,
    }
end

-- True, once, when a space is pending and the cursor has not moved. A
-- keyboard can serve several text fields, so the field must match too.
function InputController:_takePendingSpace(keyboard)
    local pending = keyboard.swype_mvp_pending_space
    keyboard.swype_mvp_pending_space = nil
    return pending ~= nil and pending.inputbox == keyboard.inputbox
        and pending.charpos == keyboard.inputbox.charpos
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
    local profile = keyboard.swype_mvp_normalization_profile
    if self.time and (self.normalization:normalizeChar(key, profile)
            or key:match("^%d$")) then
        keyboard.swype_mvp_last_letter_tap = self.time.now()
    end
    -- A space or punctuation ends a word tapped out letter by letter, if
    -- the cursor is still where the last letter was typed. An apostrophe
    -- is part of the word ("don't"); a hyphen ends only part of one
    -- ("well-known"), which is not learned.
    local inputbox = keyboard.inputbox
    local tapped = keyboard.swype_mvp_tapped_word
    local first_char = self.normalization:splitChars(key or "")[1]
    if tapped and first_char and not isApostrophe(first_char)
            and not self.normalization:normalizeChar(first_char, profile) then
        keyboard.swype_mvp_tapped_word = nil
        if first_char:match("^[%s%p]$") and not joinsWord(first_char)
                and tapped.inputbox == inputbox
                and tapped.charpos == inputbox.charpos then
            self:_learnTappedWord(keyboard)
        end
    end
    local pending_space = self:_takePendingSpace(keyboard)
    local keep_pending_space = false
    if pending_space then
        if key == " " then
            -- The space the swiped word was waiting for. With the double
            -- space option it counts as the second space, unless the word
            -- already ends in punctuation.
            local previous = keyboard.inputbox:getChar(-1)
            if self.settings:isTrue(self.DOUBLE_SPACE_SETTING)
                    and not keyboard.uwrap_func
                    and previous and not previous:match("^[%s%p]$") then
                self:commitPendingContext(keyboard)
                self:clearCandidateRow(keyboard)
                key = ". "
            end
        elseif SPACED_PUNCTUATION[key] then
            keep_pending_space = true
        elseif self.normalization:normalizeChar(
                    key, keyboard.swype_mvp_normalization_profile)
                or key:match("^%d$") then
            key = " " .. key
        end
    end
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
    local session = keyboard.swype_mvp_session
    -- Completions stay until typing pauses and they are brought up to
    -- date, saving a screen refresh per letter.
    if not keep_swype_candidates and session:getCandidates()
            and not session:getCompletion() then
        self:clearCandidateRow(keyboard)
    end
    -- A letter after a space, punctuation or nothing starts a tapped word;
    -- a letter typed where the last one was continues it.
    local key_chars = self.normalization:splitChars(key or "")
    local key_last = key_chars[#key_chars]
    local letter = key_last
        and self.normalization:normalizeChar(key_last, profile)
    local starts_word = false
    if letter then
        local before = key_chars[#key_chars - 1]
            or (inputbox.getChar and inputbox:getChar(-1))
        starts_word = not before
            or not (self.normalization:normalizeChar(before, profile)
                or isApostrophe(before) or joinsWord(before))
    end
    local charpos = inputbox.charpos
    self.logger.dbg("add char", key)
    inputbox:addChars(key)
    tapped = keyboard.swype_mvp_tapped_word
    if starts_word then
        keyboard.swype_mvp_tapped_word = {
            inputbox = inputbox,
            charpos = inputbox.charpos,
        }
        self:_warmCompletionLists(keyboard, letter)
    elseif (letter or isApostrophe(key)) and tapped
            and tapped.inputbox == inputbox and tapped.charpos == charpos then
        tapped.charpos = inputbox.charpos
    elseif letter then
        keyboard.swype_mvp_tapped_word = nil
    end
    if key == " " then
        self:_markSpace(keyboard)
    end
    if keep_pending_space then
        self:_markPendingSpace(keyboard)
    end
    local chars = self.normalization:splitChars(key or "")
    local last = chars[#chars]
    -- An apostrophe leaves the word unfinished: "don'" goes on to "don't".
    if last and (isApostrophe(last) or self.normalization:normalizeChar(
            last, keyboard.swype_mvp_normalization_profile)) then
        self:_afterManualEdit(keyboard, false)
    elseif last and (last:match("^%s$") or last:match("^%p$")) then
        self:_afterManualEdit(keyboard, true)
    else
        self:_clearPersonalOffer(keyboard)
        if session:clearCompletions() then
            keyboard:_swypeRefreshCandidateRow()
        end
    end
end

function InputController:delChar(keyboard)
    keyboard.swype_mvp_space_charpos = nil
    keyboard.swype_mvp_pending_space = nil
    if self:rejectLastInsert(keyboard) then
        return
    end
    self.logger.dbg("delete char")
    local inputbox = keyboard.inputbox
    local tapped = keyboard.swype_mvp_tapped_word
    local charpos = inputbox.charpos
    inputbox:delChar()
    -- Backspace within a tapped word keeps it one; once the word is gone,
    -- what is left before the cursor was not tapped here.
    local previous = inputbox.getChar and inputbox:getChar(-1)
    if tapped and tapped.inputbox == inputbox and tapped.charpos == charpos
            and previous and (isApostrophe(previous)
                or self.normalization:normalizeChar(previous,
                    keyboard.swype_mvp_normalization_profile)) then
        tapped.charpos = inputbox.charpos
    else
        keyboard.swype_mvp_tapped_word = nil
    end
    self:_afterManualEdit(keyboard, false)
end

return InputController
