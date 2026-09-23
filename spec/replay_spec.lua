local T = require("helper")
local it = T.it

local Replay = dofile(T.plugin_dir .. "/../tools/replay.lua")

-- Kindle-like keys, 125 x 70, rows offset by half a key.
local ROWS = { "qwertyuiop", "asdfghjkl", "zxcvbnm" }

local function keys()
    local list = {}
    for row, letters in ipairs(ROWS) do
        for index = 1, #letters do
            list[#list + 1] = {
                row = row,
                key = letters:sub(index, index),
                x = (row - 1) * 62 + (index - 1) * 125,
                y = (row - 1) * 70,
                w = 125,
                h = 70,
            }
        end
    end
    return list
end

local function center(letter)
    for _, key in ipairs(keys()) do
        if key.key == letter then
            return key.x + key.w / 2, key.y + key.h / 2
        end
    end
end

-- Pans every 10px along the key centres of word, then a pan release.
local function attemptFor(word)
    local events, t = {}, 0
    local sx, sy = center(word:sub(1, 1))
    local px, py = sx, sy
    for index = 2, #word do
        local x, y = center(word:sub(index, index))
        local steps = math.max(1,
            math.floor(math.sqrt((x - px) ^ 2 + (y - py) ^ 2) / 10))
        for step = 1, steps do
            t = t + 10000
            events[#events + 1] = {
                kind = "pan",
                t = t,
                pos = { px + (x - px) * step / steps,
                    py + (y - py) * step / steps },
                start = { sx, sy },
            }
        end
        t = t + 40000
        px, py = x, y
    end
    events[#events + 1] = {
        kind = "pan_release", t = t + 10000,
        pos = { px, py }, start = { sx, sy },
    }
    return {
        type = "attempt", target = word, dictionary = "en",
        keys = keys(), events = events, candidates = {},
    }
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
