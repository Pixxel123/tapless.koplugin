local T = require("helper")
local it = T.it

local Replay = dofile(T.plugin_dir .. "/../tools/replay.lua")

local CleanSwipes = dofile(T.plugin_dir .. "/../tools/clean_swipes.lua")
local keys = CleanSwipes.defaultKeys

-- A recorded swipe whose first choice was the word and stayed in the text.
local function attemptFor(word)
    local attempt = CleanSwipes.attempt(word, keys())
    attempt.inserted = word
    return attempt
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

-- The default keys pushed down a row, under a number row, with every swipe
-- landing on the number key above where the word's first letter is.
local function numberRowAttempt(word)
    local layout = {}
    for _, key in ipairs(keys()) do
        key.row = key.row + 1
        key.y = key.y + 70
        layout[#layout + 1] = key
    end
    local first
    for _, key in ipairs(layout) do
        first = first or (key.key == word:sub(1, 1) and key)
    end
    for index, digit in ipairs({ "1", "2", "3", "4", "5", "6", "7", "8", "9",
            "0" }) do
        table.insert(layout, index, { row = 1, key = digit,
            x = (index - 1) * 125, y = 0, w = 125, h = 70 })
    end
    local attempt = CleanSwipes.attempt(word, layout)
    local start = { first.x + 70, 60 }
    for _, event in ipairs(attempt.events) do
        event.start = start
    end
    return attempt
end

it("replays a swipe that began on the number row above its first key",
        function()
    T.eq(Replay.run(plugin, numberRowAttempt("water")).words[1], "water")
end)

-- A plugin from before number-row starts: its geometry has no startKeyAt.
local function oldPlugin()
    local geometry = setmetatable({}, { __index = function(_, name)
        if name ~= "startKeyAt" then
            return function(_, ...)
                return plugin.geometry[name](plugin.geometry, ...)
            end
        end
    end })
    return setmetatable({ geometry = geometry }, { __index = plugin })
end

it("replays with a plugin from before number-row starts", function()
    local old = oldPlugin()
    T.truthy(Replay.run(old, numberRowAttempt("water")).short)
    T.eq(Replay.run(old, attemptFor("water")).words[1], "water")
end)

it("knows a swipe began on a number key", function()
    T.eq(Replay.startedOnNumberKey(plugin, numberRowAttempt("water")), true)
    T.eq(Replay.startedOnNumberKey(plugin, attemptFor("water")), false)
    T.eq(Replay.startedOnNumberKey(plugin, { keys = {}, events = {} }), false)
    T.eq(Replay.startedOnNumberKey(plugin, {}), false)
    -- A plugin from before number-row starts cannot say.
    T.eq(Replay.startedOnNumberKey(oldPlugin(), numberRowAttempt("water")),
        false)
end)

-- The dispatched gestures of a swipe from the number row: a swipe KOReader
-- took, a tap on a digit, and then the attempt's own swipe.
local function numberRowGestures(attempt)
    local start = attempt.events[1].start
    return {
        { ges = "touch", pos = { 100, 100 } },
        { ges = "swipe", pos = { 100, 100 } },
        { ges = "touch", pos = start },
        { ges = "pan", pos = { start[1] + 5, start[2] } },
        { ges = "multiswipe", pos = start },
        { ges = "touch", pos = { 300, 30 } },
        { ges = "tap", pos = { 300, 30 } },
        { ges = "touch", pos = start },
        { ges = "pan", pos = { start[1] + 20, start[2] + 30 } },
        { ges = "swipe", pos = start },
    }
end

it("lists the swipes from a number key that were left to KOReader", function()
    local attempt = numberRowAttempt("water")
    attempt.gestures = numberRowGestures(attempt)
    local left = Replay.numberKeyGestures(plugin, attempt)
    T.eq(#left, 1, "the attempt's own swipe is not one of them")
    T.eq(left[1].ends, "multiswipe")
    T.eq(left[1].pans, 1)
    T.eq(left[1].pos[1], attempt.events[1].start[1])
end)

it("counts every swipe from a number key when the attempt began elsewhere",
        function()
    local attempt = numberRowAttempt("water")
    attempt.gestures = numberRowGestures(attempt)
    local start = attempt.events[1].start
    -- The attempt's own swipe began on the letter below instead.
    for _, event in ipairs(attempt.events) do
        event.start = { start[1], 100 }
    end
    local left = Replay.numberKeyGestures(plugin, attempt)
    T.eq(#left, 2)
    T.eq(left[2].ends, "swipe")
    T.eq(#Replay.numberKeyGestures(plugin, attemptFor("water")), 0)
    T.eq(#Replay.numberKeyGestures(oldPlugin(), attempt), 0,
        "an older plugin cannot say")
end)

it("counts a slide that ends in a pan release", function()
    local attempt = numberRowAttempt("water")
    local start = attempt.events[1].start
    for _, event in ipairs(attempt.events) do
        event.start = { start[1], 100 }
    end
    attempt.gestures = {
        { ges = "touch", pos = start },
        { ges = "pan", pos = { start[1], start[2] + 4 } },
        { ges = "pan_release", pos = { start[1], start[2] + 4 } },
    }
    local left = Replay.numberKeyGestures(plugin, attempt)
    T.eq(#left, 1)
    T.eq(left[1].ends, "pan_release")
end)

it("reports how often each suggestion was kept", function()
    local seeded = Replay.loadPlugin(T.plugin_dir,
        { usage = true, usage_counts = { wafer = 5, water = 1 } })
    local result = Replay.run(seeded, attemptFor("water"))
    local counts = { wafer = 5, water = 1 }
    T.truthy(#result.words > 1)
    for index, word in ipairs(result.words) do
        T.eq(result.uses[index], counts[word] or 0, word)
    end
    T.eq(#Replay.run(plugin, attemptFor("water")).uses, 0,
        "no usage model, no counts")
end)

it("tells a learned word put first from one that was right", function()
    local function learnedFirst(words, uses, target)
        return Replay.learnedFirst({ words = words, uses = uses }, target)
    end
    T.eq(learnedFirst({ "water" }, { 2 }, "Water"), "right")
    T.eq(learnedFirst({ "wafer", "water" }, { 4, 0 }, "water"), "wrong")
    T.eq(learnedFirst({ "wafer" }, { 1 }, "water"), nil, "used only once")
    T.eq(learnedFirst({ "wafer" }, { 0 }, "wafer"), nil)
    T.eq(Replay.learnedFirst({ words = { "water" }, uses = {} }, "water"), nil)
    T.eq(Replay.learnedFirst({ words = {} , uses = {} }, "water"), nil)
end)

it("keeps counts as they stood on the device when frozen", function()
    local frozen = Replay.loadPlugin(T.plugin_dir, { context = true,
        usage = true, usage_counts = { water = 3 }, frozen = true })
    local attempt = attemptFor("water")
    attempt.previous_word = "the"
    Replay.learn(frozen, attempt)
    T.eq(frozen.usage_model:uses("water"), 3)
    T.eq(frozen.context_model:bonus("the", "water"), 0)
    frozen:resetLearning()
    Replay.learn(frozen, attempt)
    T.eq(frozen.usage_model:uses("water"), 3, "still frozen after a reset")
end)

it("counts the words a usage model holds", function()
    local seeded = Replay.loadPlugin(T.plugin_dir, { usage = true,
        usage_counts = { a = 1, b = 2, c = 9 } })
    local known, twice = Replay.usageSize(seeded)
    T.eq(known, 3)
    T.eq(twice, 2)
    T.eq(Replay.usageSize(plugin), nil)
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

it("scores with the dictionary's word-pair table, unless told not to",
        function()
    local attempt = attemptFor("water")
    attempt.previous_word = "the"
    local store = plugin.engine.dictionary_store
    local result = Replay.run(plugin, attempt)
    T.eq(result.bonus[1], store:pairBonus("the", result.words[1], "en"))
    local with_context = Replay.loadPlugin(T.plugin_dir, { context = true })
    with_context.context_model:learn("the", result.words[1])
    T.eq(Replay.run(with_context, attempt).bonus[1],
        with_context.context_model:bonus("the", result.words[1],
            store:pairBonus("the", result.words[1], "en")),
        "learned and table bonus together")
    local without = Replay.loadPlugin(T.plugin_dir, { no_pairs = true })
    T.eq(Replay.run(without, attempt).bonus[1], nil)
    T.eq(without.engine.dictionary_store:pairBonus("the", "water", "en"), 0)
end)

it("times each swipe and averages the times", function()
    local result = Replay.run(plugin, attemptFor("water"))
    T.eq(type(result.ms), "number")
    T.truthy(result.ms >= 0)
    local summary = Replay.summarize({
        { target = "water", words = { "water" }, ms = 2 },
        { target = "hello", words = { "hello" }, ms = 4 },
        { target = "cold", words = { "could" } },
    })
    T.eq(summary.all.ms, 6)
    T.eq(summary.all.timed, 2)
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

it("gives a plugin a usage model only when its code has one", function()
    T.eq(Replay.loadPlugin(T.plugin_dir).usage_model, nil)
    T.truthy(Replay.loadPlugin(T.plugin_dir, { usage = true }).usage_model)
    -- A plugin from before usage learning can neither learn nor use counts.
    local dir = os.tmpname()
    os.remove(dir)
    os.execute('cp -r "' .. T.plugin_dir .. '" "' .. dir .. '"')
    os.remove(dir .. "/usage_model.lua")
    local old = Replay.loadPlugin(dir, { usage = true })
    local first = Replay.run(old, attemptFor("water")).words[1]
    os.execute('rm -rf "' .. dir .. '"')
    T.eq(old.usage_model, nil)
    T.eq(first, "water")
end)

it("lets the words a user keeps change the first choice", function()
    local seeded = Replay.loadPlugin(T.plugin_dir,
        { usage = true, usage_counts = { wafer = 255 } })
    local scoring = seeded.engine.scoring
    scoring.USAGE_UNIT, scoring.USAGE_CAP, scoring.USAGE_CEILING = 1e7, 1e7, 1e7
    T.eq(Replay.run(seeded, attemptFor("water")).words[1], "wafer")
    local unseeded = Replay.loadPlugin(T.plugin_dir, { usage = true })
    T.eq(Replay.run(unseeded, attemptFor("water")).words[1], "water")
end)

it("learns the uses of the kept word after its swipe", function()
    local with_usage = Replay.loadPlugin(T.plugin_dir, { usage = true })
    local picked = attemptFor("water")
    picked.picked = "wafer"
    Replay.learn(with_usage, picked)
    T.eq(with_usage.usage_model:uses("wafer"), 2)
    Replay.learn(with_usage, attemptFor("water"))
    T.eq(with_usage.usage_model:uses("water"), 1)
    Replay.learn(plugin, picked)  -- no usage model: no error
end)

it("starts learning again from the seeded counts", function()
    local both = Replay.loadPlugin(T.plugin_dir, { context = true,
        usage = true, usage_counts = { wafer = 3 } })
    both.usage_model:learn("wafer", 5)
    both.usage_model:learn("water", 1)
    both.context_model:learn("the", "water")
    both:resetLearning()
    T.eq(both.usage_model:uses("wafer"), 3, "the seed")
    T.eq(both.usage_model:uses("water"), 0)
    T.eq(both.context_model:bonus("the", "water"), 0)
    plugin:resetLearning()  -- no models: no error
end)

it("learns the word the device kept, not the intended one", function()
    local with_context = Replay.loadPlugin(T.plugin_dir, { context = true })
    local attempt = attemptFor("water")
    attempt.previous_word = "the"
    attempt.inserted = "wafer"
    Replay.learn(with_context, attempt)
    T.truthy(with_context.context_model:bonus("the", "wafer") > 0,
        "the -> wafer learned")
    T.eq(with_context.context_model:bonus("the", "water"), 0)
end)

it("learns nothing from a word that was deleted again", function()
    local with_context = Replay.loadPlugin(T.plugin_dir, { context = true })
    local attempt = attemptFor("water")
    attempt.previous_word = "the"
    attempt.deleted = true
    Replay.learn(with_context, attempt)
    T.eq(with_context.context_model:bonus("the", "water"), 0)
end)

it("counts a pick twice and the first choice once", function()
    local word, uses = Replay.kept({ inserted = "wafer", picked = "water" })
    T.eq(word, "water")
    T.eq(uses, 2)
    word, uses = Replay.kept({ inserted = "wafer" })
    T.eq(word, "wafer")
    T.eq(uses, 1)
    T.eq(Replay.kept({ inserted = "wafer", deleted = true }), nil)
    T.eq(Replay.kept({ short = true }), nil)
    T.eq(Replay.kept({}), nil)
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

it("attaches a pick and a deletion to their own attempt", function()
    local path = os.tmpname()
    local file = assert(io.open(path, "w"))
    file:write("one\npick\ntwo\ndeleted\nnext\n")
    file:close()
    local function attempt(id, target)
        return { type = "attempt", id = id, target = target, keys = {} }
    end
    local records = {
        one = attempt(1, "water"),
        pick = { type = "outcome", id = 1, outcome = "picked",
            word = "wafer" },
        two = attempt(2, "hello"),
        deleted = { type = "outcome", id = 2, outcome = "deleted" },
        -- A new session starts its ids again at 1.
        next = attempt(1, "world"),
    }
    local json = { decode = function(line) return records[line] end }
    local attempts = Replay.readSessions({ path, path }, json,
        { keep_suspect = true })
    os.remove(path)
    T.eq(#attempts, 6)
    T.eq(attempts[1].picked, "wafer")
    T.eq(attempts[1].deleted, nil)
    T.eq(attempts[2].deleted, true)
    T.eq(attempts[2].picked, nil)
    T.eq(attempts[3].picked, nil, "the next session's attempt 1 is its own")
end)
