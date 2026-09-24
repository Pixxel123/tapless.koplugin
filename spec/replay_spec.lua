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
    -- water first, hello second, cold missing: 1 + 1/2 + 0.
    T.eq(summary.all.rr, 1.5)
    T.eq(summary.groups.b.rr, 0)
end)

it("gives the chance a fixed/broken split is luck", function()
    local function near(actual, expected)
        T.truthy(math.abs(actual - expected) < 1e-9,
            "expected " .. expected .. ", got " .. actual)
    end
    near(Replay.mcnemar(5, 1), 0.21875)
    near(Replay.mcnemar(1, 5), 0.21875)
    near(Replay.mcnemar(10, 0), 0.001953125)
    T.eq(Replay.mcnemar(3, 3), 1)
    T.eq(Replay.mcnemar(0, 0), 1)
    -- Large counts must not underflow to zero or overflow.
    local p = Replay.mcnemar(700, 650)
    T.truthy(p > 0.15 and p < 0.2, "700/650 gave " .. p)
end)

it("replays with personal words from a folder", function()
    local dir = os.tmpname()
    os.remove(dir)
    os.execute('mkdir -p "' .. dir .. '"')
    local file = assert(io.open(dir .. "/en.txt", "w"))
    file:write("# Tapless personal dictionary v1\nwater\n")
    file:close()
    local with_personal = Replay.loadPlugin(T.plugin_dir,
        { personal_dir = dir })
    local result = Replay.run(with_personal, attemptFor("water"))
    T.eq(result.words[1], "water")
    T.eq(result.personal[1], true)
    T.eq(Replay.run(plugin, attemptFor("water")).personal[1], false)
    os.remove(dir .. "/en.txt")
    os.remove(dir)
end)

it("lets a learned word pair change the first choice", function()
    local with_context = Replay.loadPlugin(T.plugin_dir, { context = true })
    local attempt = attemptFor("water")
    attempt.previous_word = "the"
    T.eq(Replay.run(with_context, attempt).words[1], "water")
    -- Every word but water now follows "the" as often as it can.
    with_context.context_model.bonus = function(_, previous, word)
        return previous == "the" and word ~= "water" and 1e7 or 0
    end
    local result = Replay.run(with_context, attempt)
    T.truthy(result.words[1] ~= "water", "a paired word came first")
    T.eq(result.bonus[1], 1e7)
end)

it("learns the intended word after its swipe", function()
    local with_context = Replay.loadPlugin(T.plugin_dir, { context = true })
    local attempt = attemptFor("water")
    attempt.previous_word = "The"
    Replay.learn(with_context, attempt)
    T.truthy(with_context.context_model:bonus("the", "water") > 0,
        "the -> water learned")
    Replay.learn(plugin, attempt)  -- no context model: no error
end)

it("classifies a loss stage before its own pair is learned, but "
        .. "after an earlier attempt's", function()
    local with_context = Replay.loadPlugin(T.plugin_dir, { context = true })
    local first = attemptFor("water")
    first.previous_word = "the"
    local second = attemptFor("water")
    second.previous_word = "the"
    -- Boosts every rival of water, but only until "the" has paired
    -- with water once -- mirrors what a real learned pair does,
    -- without depending on scoring's raw preference between words.
    with_context.context_model.bonus = function(_, previous, word)
        local counts = with_context.context_model:getCounts()
        local learned = previous == "the" and counts["the"]
            and counts["the"]["water"]
        return (not learned or learned == 0) and word ~= "water"
            and 1e7 or 0
    end
    -- Drives the same function main's per-attempt loop calls, so
    -- reverting its lossStage-before-learn order would fail this.
    local _, stage1 = Replay.replayAttempt(with_context, nil, first, true)
    T.truthy(stage1 ~= "first",
        "water should not be first before its own pair is learned")
    -- The pair learned from "first" is available to "second", a
    -- later attempt with the same previous word.
    local _, stage2 = Replay.replayAttempt(with_context, nil, second, true)
    T.eq(stage2, "first")
end)

it("names the stage where the intended word was lost", function()
    local attempt = attemptFor("water")
    T.eq(Replay.lossStage(plugin, attempt), "first")
    -- A swipe from w to r never searches words from h to o.
    attempt.target = "hello"
    T.eq(Replay.lossStage(plugin, attempt), "not scanned")
    -- The engine is left as it was.
    T.eq(rawget(plugin.engine.scoring, "scoreEntry"), nil)
    T.eq(Replay.run(plugin, attemptFor("water")).words[1], "water")
end)

it("names why a recorded attempt should be left out", function()
    local good = { mode = "sentences", target = "like",
        previous_word = "you",
        keys = { { x = 0, y = 0 }, { x = 10, y = 0 } } }
    T.eq(Replay.auditAttempt(good), nil)
    T.eq(Replay.auditAttempt({ mode = "words", target = "like",
        previous_word = "ulike", keys = {} }), nil)
    T.eq(Replay.auditAttempt({ mode = "sentences", target = "like",
        previous_word = "uLike", keys = {} }), "target already typed")
    T.eq(Replay.auditAttempt({ mode = "sentences", target = "to",
        after_uncorrected = 3, keys = {} }), "after an uncorrected word")
    T.eq(Replay.auditAttempt({ mode = "words", target = "please",
        keys = { { x = 0, y = 0 }, { x = 0, y = 0 },
            { x = 5, y = 5, candidate = true } } }), "keys not laid out")
end)

it("reads sessions and leaves out suspect attempts", function()
    local path = os.tmpname()
    local file = assert(io.open(path, "w"))
    file:write("start\ngood\nahead\nempty\n")
    file:close()
    local records = {
        start = { type = "start", mode = "sentences" },
        good = { type = "attempt", target = "you", previous_word = "would",
            keys = {} },
        ahead = { type = "attempt", target = "like", previous_word = "like",
            keys = {} },
        empty = { type = "attempt", target = "to", previous_word = "like",
            keys = { { x = 0, y = 0 }, { x = 0, y = 0 } } },
    }
    local json = { decode = function(line) return records[line] end }
    local attempts, left_out = Replay.readSessions({ path }, json)
    T.eq(#attempts, 1)
    T.eq(attempts[1].target, "you")
    T.eq(attempts[1].mode, "sentences")
    T.eq(attempts[1].session, 1)
    T.eq(left_out["target already typed"], 1)
    T.eq(left_out["keys not laid out"], 1)
    local all = Replay.readSessions({ path }, json, { keep_suspect = true })
    T.eq(#all, 3)
    os.remove(path)
end)
