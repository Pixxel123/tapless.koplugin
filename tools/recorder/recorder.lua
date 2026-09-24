-- Session logic for Tapless swipe test sessions. The KOReader patch in
-- tools/recorder_patch.lua feeds it keyboard calls, a clock and a sink;
-- nothing here touches KOReader.
local Recorder = {}
Recorder.__index = Recorder

-- options: prompts (from Recorder.parsePrompts), write(record),
-- now() in microseconds, show(text), mode ("words" or "sentences").
function Recorder:new(options)
    return setmetatable({
        prompts = assert(options.prompts),
        write = assert(options.write),
        now = assert(options.now),
        show = options.show or function() end,
        mode = options.mode or "words",
        position = 1,
        next_id = 1,
        events = nil,
        event_start = nil,
        origin = nil,
        candidate_list = nil,
        dispatched_list = {},
        last_attempt = nil,
        held = nil,
        finished = false,
    }, self)
end

-- Words mode: one word per line. Sentences mode: one sentence per line,
-- prompted a word at a time. number and total count lines.
function Recorder.parsePrompts(lines, mode)
    local prompts, count = {}, 0
    for _, line in ipairs(lines) do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" then
            count = count + 1
            if mode == "sentences" then
                local words = {}
                for word in line:gmatch("%S+") do
                    words[#words + 1] = word
                end
                for index, word in ipairs(words) do
                    -- One-letter words ("i", "a") make too short a swipe
                    -- to record; the tester taps them instead, so only
                    -- longer words become prompts. They stay in `words`
                    -- so the sentence still shows in full.
                    if #word >= 2 then
                        prompts[#prompts + 1] = {
                            target = word,
                            number = count,
                            sentence = line,
                            words = words,
                            word_index = index,
                        }
                    end
                end
            else
                prompts[#prompts + 1] = { target = line, number = count }
            end
        end
    end
    for _, prompt in ipairs(prompts) do
        prompt.total = count
    end
    return prompts
end

-- Prompts are lowercase words; Tapless may capitalise what it types.
local function sameWord(word, target)
    return word ~= nil and target ~= nil and word:lower() == target:lower()
end

function Recorder:promptText()
    local prompt = self.prompts[self.position]
    if not prompt then
        return "Session finished"
    end
    if prompt.words then
        local parts = {}
        for index, word in ipairs(prompt.words) do
            parts[index] = index == prompt.word_index
                and "[" .. word .. "]" or word
        end
        return string.format("%s (%d/%d)", table.concat(parts, " "),
            prompt.number, prompt.total)
    end
    return string.format("Swipe: %s (%d/%d)", prompt.target,
        prompt.number, prompt.total)
end

function Recorder:showPrompt()
    local held = self.held
    local prompt = self.prompts[self.position]
    if held and prompt then
        self.show(string.format(
            'Typed "%s", not "%s": delete it or pick "%s"\n%s',
            held.word, prompt.target, prompt.target, self:promptText()))
    else
        self.show(self:promptText())
    end
end

function Recorder:start(info)
    local record = {
        type = "start",
        time = os.time(),
        mode = self.mode,
        prompts = #self.prompts,
    }
    for key, value in pairs(info or {}) do
        record[key] = value
    end
    self.write(record)
    self:showPrompt()
end

local function point(pos)
    if pos and pos.x and pos.y then
        return { pos.x, pos.y }
    end
end

-- Called before Tapless handles a gesture. kind: pan, pan_release, swipe
-- or multiswipe; key: letter of the key a swipe was routed from.
function Recorder:gesture(kind, ges, key)
    if self.finished or not ges then
        return
    end
    local now = self.now()
    local start = point(ges.start_pos)
    local new_gesture = not self.events
        or (start and self.event_start
            and (start[1] ~= self.event_start[1]
                or start[2] ~= self.event_start[2]))
    if new_gesture then
        self.events = {}
        self.event_start = start
        self.origin = now
    end
    self.event_start = self.event_start or start
    self.events[#self.events + 1] = {
        kind = kind,
        t = now - self.origin,
        pos = point(ges.pos),
        start = start,
        ["end"] = point(ges.end_pos),
        key = key,
    }
end

-- Tapless did not take the gesture: it is not part of a swipe.
-- Every gesture KOReader dispatched, whichever widget took it, kept with
-- the next attempt. top: the window it was sent to first.
function Recorder:dispatched(ges, top)
    if self.finished or not ges then
        return
    end
    local list = self.dispatched_list
    if #list >= 400 then
        table.remove(list, 1)
    end
    list[#list + 1] = {
        ges = ges.ges,
        pos = point(ges.pos),
        time = ges.time,
        top = top,
    }
end

function Recorder:dropGesture()
    self.events, self.event_start, self.origin = nil, nil, nil
end

function Recorder:candidates(list)
    local copy = {}
    for index, candidate in ipairs(list or {}) do
        copy[index] = {
            word = candidate.word,
            output_word = candidate.output_word,
            spatial = candidate.spatial_score,
            ranked = candidate.ranked_score,
            personal = candidate.personal or nil,
        }
    end
    self.candidate_list = copy
end

-- Called after Tapless finished a trace. context: keys (list of key
-- rectangles) and dictionary.
function Recorder:finalize(signature, trace_info, context)
    if self.finished then
        return
    end
    signature = signature or ""
    local prompt = self.prompts[self.position]
    local candidates = self.candidate_list or {}
    local short = #signature < 2
    local inserted = not short and candidates[1]
        and candidates[1].word or nil
    -- true or false when a word was typed, nil when none was. (Not an
    -- and/or expression: `inserted and false or nil` would give nil.)
    local matched
    if inserted then
        matched = sameWord(inserted, prompt and prompt.target)
    end
    local after_uncorrected = self.held and self.held.id or nil
    local id = self.next_id
    self.next_id = id + 1
    self.write{
        type = "attempt",
        id = id,
        prompt = self.position,
        target = prompt and prompt.target,
        sentence = prompt and prompt.sentence,
        dictionary = context and context.dictionary,
        previous_word = trace_info and trace_info.previous_word,
        keys = context and context.keys or {},
        events = self.events or {},
        letters = signature,
        released = trace_info and trace_info.released or false,
        candidates = candidates,
        inserted = inserted,
        matched = matched,
        word_index = prompt and prompt.word_index,
        after_uncorrected = after_uncorrected,
        short = short,
        gestures = self.dispatched_list,
    }
    self.last_attempt = { id = id, position = self.position }
    self:dropGesture()
    self.dispatched_list = {}
    self.candidate_list = nil
    -- In a sentence the tester reads on from what is typed, so moving
    -- on past a wrong word would label later swipes with the wrong word.
    if inserted and (matched or self.mode ~= "sentences") then
        self.held = nil
        self:advance()
    elseif inserted then
        self.held = { id = id, word = inserted }
        self:showPrompt()
    else
        self:showPrompt()
    end
end

function Recorder:advance()
    self.position = self.position + 1
    if self.position > #self.prompts then
        self:finish()
    else
        self:showPrompt()
    end
end

function Recorder:finish()
    if self.finished then
        return
    end
    self.finished = true
    self.write{ type = "end", time = os.time() }
    self.show("Session finished")
end

function Recorder:picked(index, word)
    local last = self.last_attempt
    if not last then
        return
    end
    self.write{
        type = "outcome",
        id = last.id,
        outcome = "picked",
        index = index,
        word = word,
    }
    local prompt = self.prompts[self.position]
    if self.held and sameWord(word, prompt and prompt.target) then
        self.held = nil
        self:advance()
    end
end

-- The swiped word was removed with backspace: ask for it again.
function Recorder:deleted()
    local last = self.last_attempt
    if not last then
        return
    end
    self.last_attempt = nil
    self.held = nil
    self.write{ type = "outcome", id = last.id, outcome = "deleted" }
    if not self.finished then
        self.position = last.position
        self:showPrompt()
    end
end

return Recorder
