local T = require("helper")
local it = T.it

local Replay = dofile(T.plugin_dir .. "/../tools/replay.lua")

local CleanSwipes = dofile(T.plugin_dir .. "/../tools/clean_swipes.lua")
local keys = CleanSwipes.defaultKeys

local function attemptFor(word)
    return CleanSwipes.attempt(word, keys())
end

local plugin = Replay.loadPlugin(T.plugin_dir)

it("replays a recorded swipe to the intended word", function()
    for _, word in ipairs({ "water", "hello" }) do
        local result = Replay.run(plugin, attemptFor(word))
        T.eq(result.words[1], word, word)
        T.truthy(#result.letters >= #word - 1, "letters " .. result.letters)
    end
end)

it("reports a one-letter trace as short", function()
    local attempt = attemptFor("water")
    attempt.events = { attempt.events[1] }
    attempt.events[1].kind = "pan_release"
    T.truthy(Replay.run(plugin, attempt).short)
end)

it("treats a point on a key edge as KOReader does", function()
    -- 100,70 sits exactly on the q/a row boundary (row 1 y 0..70, row 2
    -- y 70..140) and inside both columns (q x 0..125, a x 62..187), so a
    -- device-accurate contains() must pick q, the first match in layout
    -- order.
    local start = { 100, 70 }
    local events = {
        { kind = "pan", t = 10000, pos = start, start = start },
        { kind = "pan", t = 20000, pos = { 150, 105 }, start = start },
        { kind = "pan", t = 30000, pos = { 250, 105 }, start = start },
        { kind = "pan", t = 40000, pos = { 350, 105 }, start = start },
        { kind = "pan_release", t = 50000, pos = { 400, 105 }, start = start },
    }
    local attempt = {
        type = "attempt", target = "asdf", dictionary = "en",
        keys = keys(), events = events, candidates = {},
    }
    T.eq(Replay.run(plugin, attempt).letters:sub(1, 1), "q")
end)

it("summarizes first-choice and top-four accuracy", function()
    local summary = Replay.summarize({
        { target = "water", words = { "water", "wafer" }, group = "a" },
        { target = "hello", words = { "hell", "hello" }, group = "a" },
        { target = "cold", words = { "could" }, group = "b" },
    }, function(row) return row.group end)
    T.eq(summary.all.n, 3)
    T.eq(summary.all.top1, 1)
    T.eq(summary.all.top4, 2)
    T.eq(summary.groups.a.top4, 2)
    T.eq(summary.groups.b.top1, 0)
end)
