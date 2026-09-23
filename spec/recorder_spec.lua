local T = require("helper")
local it = T.it

local function load()
    return dofile(T.plugin_dir .. "/../tools/recorder/recorder.lua")
end

local function newRecorder(lines, mode)
    local Recorder = load()
    local state = { records = {}, shown = {}, clock = 1000 }
    local recorder = Recorder:new{
        prompts = Recorder.parsePrompts(lines, mode),
        mode = mode,
        write = function(record) table.insert(state.records, record) end,
        now = function()
            state.clock = state.clock + 10
            return state.clock
        end,
        show = function(text) table.insert(state.shown, text) end,
    }
    return recorder, state
end

local function pos(x, y) return { x = x, y = y } end

local function swipe(recorder, letters, candidates)
    recorder:gesture("pan", { pos = pos(10, 10), start_pos = pos(5, 5) })
    recorder:gesture("pan_release",
        { pos = pos(40, 10), start_pos = pos(5, 5) })
    if candidates then
        recorder:candidates(candidates)
    end
    recorder:finalize(letters, { released = true, previous_word = "the" }, {
        dictionary = "en",
        keys = { { row = 2, key = "a", x = 0, y = 0, w = 10, h = 10 } },
    })
end

local function last(state) return state.records[#state.records] end

it("splits sentence prompts into words", function()
    local Recorder = load()
    local prompts = Recorder.parsePrompts({ "the water is cold", "" },
        "sentences")
    T.eq(#prompts, 4)
    T.eq(prompts[2].target, "water")
    T.eq(prompts[2].number, 1)
    T.eq(prompts[2].total, 1)
end)

it("skips one-letter words as prompt targets in sentence mode", function()
    local Recorder = load()
    local prompts = Recorder.parsePrompts({ "i left my keys" }, "sentences")
    T.eq(#prompts, 3)
    T.eq(prompts[1].target, "left")
    T.eq(prompts[2].target, "my")
    T.eq(prompts[3].target, "keys")
end)

it("brackets the prompted word when the sentence starts with a " ..
        "one-letter word", function()
    local sentences = newRecorder({ "i left my keys" }, "sentences")
    T.eq(sentences:promptText(), "i [left] my keys (1/1)")
end)

it("formats word and sentence prompts", function()
    local words = newRecorder({ "water", "hello" })
    T.eq(words:promptText(), "Swipe: water (1/2)")
    local sentences = newRecorder({ "the water is cold" }, "sentences")
    sentences.position = 2
    T.eq(sentences:promptText(), "the [water] is cold (1/1)")
    words.position = 3
    T.eq(words:promptText(), "Session finished")
end)

it("records a swipe and moves to the next prompt", function()
    local recorder, state = newRecorder({ "water", "hello" })
    recorder:start{ screen = { 100, 200 } }
    T.eq(state.records[1].type, "start")
    T.eq(state.records[1].prompts, 2)
    T.eq(state.shown[1], "Swipe: water (1/2)")
    swipe(recorder, "wafer", {
        { word = "water", spatial_score = 1, ranked_score = -500 },
        { word = "wafer", spatial_score = 2, ranked_score = 100 },
    })
    local attempt = last(state)
    T.eq(attempt.type, "attempt")
    T.eq(attempt.id, 1)
    T.eq(attempt.target, "water")
    T.eq(attempt.letters, "wafer")
    T.eq(attempt.inserted, "water")
    T.eq(attempt.previous_word, "the")
    T.eq(attempt.dictionary, "en")
    T.eq(#attempt.events, 2)
    T.eq(attempt.events[1].t, 0)
    T.eq(attempt.events[2].t, 10)
    T.eq(attempt.events[2].kind, "pan_release")
    T.eq(attempt.events[1].start[1], 5)
    T.eq(attempt.candidates[2].word, "wafer")
    T.eq(attempt.candidates[1].ranked, -500)
    T.eq(attempt.short, false)
    T.eq(state.shown[#state.shown], "Swipe: hello (2/2)")
end)

it("prompts the same word again after a short trace", function()
    local recorder, state = newRecorder({ "water", "hello" })
    recorder:start()
    swipe(recorder, "w")
    T.eq(last(state).short, true)
    T.eq(last(state).inserted, nil)
    T.eq(state.shown[#state.shown], "Swipe: water (1/2)")
end)

it("prompts the same word again when nothing was typed", function()
    local recorder, state = newRecorder({ "water", "hello" })
    recorder:start()
    swipe(recorder, "wqzx", {})
    T.eq(last(state).inserted, nil)
    T.eq(state.shown[#state.shown], "Swipe: water (1/2)")
end)

it("records a deleted swipe and asks for the word again", function()
    local recorder, state = newRecorder({ "water", "hello" })
    recorder:start()
    swipe(recorder, "wafer", { { word = "wafer" } })
    recorder:deleted()
    local outcome = last(state)
    T.eq(outcome.type, "outcome")
    T.eq(outcome.id, 1)
    T.eq(outcome.outcome, "deleted")
    T.eq(state.shown[#state.shown], "Swipe: water (1/2)")
    swipe(recorder, "water", { { word = "water" } })
    T.eq(last(state).target, "water")
    T.eq(last(state).id, 2)
end)

it("records a picked suggestion", function()
    local recorder, state = newRecorder({ "water", "hello" })
    recorder:start()
    swipe(recorder, "wafer", { { word = "wafer" }, { word = "water" } })
    recorder:picked(2, "water")
    local outcome = last(state)
    T.eq(outcome.outcome, "picked")
    T.eq(outcome.index, 2)
    T.eq(outcome.word, "water")
end)

it("starts a new gesture when a pan starts somewhere else", function()
    local recorder, state = newRecorder({ "water", "hello" })
    recorder:start()
    recorder:gesture("pan", { pos = pos(10, 10), start_pos = pos(1, 1) })
    recorder:gesture("pan", { pos = pos(20, 10), start_pos = pos(9, 9) })
    recorder:candidates({ { word = "water" } })
    recorder:finalize("water", { released = true }, { keys = {} })
    T.eq(#last(state).events, 1)
    T.eq(last(state).events[1].start[1], 9)
end)

it("drops a gesture that Tapless did not handle", function()
    local recorder, state = newRecorder({ "water", "hello" })
    recorder:start()
    recorder:gesture("pan", { pos = pos(10, 10), start_pos = pos(1, 1) })
    recorder:dropGesture()
    recorder:candidates({ { word = "water" } })
    recorder:finalize("water", { released = true }, { keys = {} })
    T.eq(#last(state).events, 0)
end)

it("ends the session once after the last prompt", function()
    local recorder, state = newRecorder({ "water" })
    recorder:start()
    swipe(recorder, "water", { { word = "water" } })
    T.eq(last(state).type, "end")
    T.eq(state.shown[#state.shown], "Session finished")
    local count = #state.records
    swipe(recorder, "hello", { { word = "hello" } })
    T.eq(#state.records, count)
end)

it("keeps every dispatched gesture with the next attempt", function()
    local recorder, state = newRecorder({ "water", "hello" })
    recorder:start()
    recorder:dispatched({ ges = "hold", pos = pos(3, 4), time = 7 }, "popup")
    swipe(recorder, "water", { { word = "water" } })
    local gestures = state.records[2].gestures
    T.eq(#gestures, 1)
    T.eq(gestures[1].ges, "hold")
    T.eq(gestures[1].pos[1], 3)
    T.eq(gestures[1].top, "popup")
    T.eq(gestures[1].time, 7)
    swipe(recorder, "hello", { { word = "hello" } })
    T.eq(#state.records[3].gestures, 0)
end)
