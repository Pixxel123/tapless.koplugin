local T = require("helper")
local it = T.it

local InputController = T.load("input_controller")
local InputSession = T.load("input_session")
local Replay = dofile(T.plugin_dir .. "/../tools/replay.lua")

local function noop() end

-- Just enough of KOReader's InputText for typing at the cursor.
local function newInputBox()
    local box = { charlist = {}, charpos = 1 }
    function box:getChar(offset)
        return self.charlist[self.charpos + offset]
    end
    function box:addChars(chars)
        for char in chars:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            table.insert(self.charlist, self.charpos, char)
            self.charpos = self.charpos + 1
        end
    end
    function box:delChar()
        if self.charpos > 1 then
            table.remove(self.charlist, self.charpos - 1)
            self.charpos = self.charpos - 1
        end
    end
    function box:getText()
        return table.concat(self.charlist)
    end
    return box
end

local WORDS = { "hello", "help", "helmet", "the", "there", "their", "then",
    "world", "would", "word", "say", "don't", "done", "I'm" }

-- A word's letters, as the word lists are keyed: "don't" is "dont".
local function signature(word)
    return (word:lower():gsub("'", ""))
end

-- The helper's normalization, but normalizing whole words too.
local normalization = setmetatable({
    normalizeText = function(self, text)
        local letters = {}
        for _, char in ipairs(self:splitChars(text)) do
            letters[#letters + 1] = self:normalizeChar(char)
        end
        return table.concat(letters)
    end,
}, { __index = T.normalization })

-- A controller and keyboard typing into a fake text box. Completions come
-- from WORDS, in order; learning and timers are recorded.
local function setup(options)
    options = options or {}
    local state = { timers = {}, pairs = {}, uses = {}, refreshes = 0,
        asked = {} }
    local ui_manager = {
        scheduleIn = function(_, _, fn) table.insert(state.timers, fn) end,
    }
    local context_model = {
        commit = noop, save = noop,
        learn = function(_, previous, word)
            table.insert(state.pairs, (previous or "-") .. " " .. word)
        end,
    }
    local usage_model = {
        commit = noop, save = noop,
        uses = function() return 0 end,
        learn = function(_, word, uses)
            state.uses[word] = (state.uses[word] or 0) + (uses or 1)
        end,
    }
    local known = {}
    for _, word in ipairs(WORDS) do known[word:lower()] = word end
    local personal = {
        prepareWord = function(_, word)
            if type(word) ~= "string" or #word < 2 then return end
            return word:lower(), word:lower()
        end,
        contains = function() return false end,
    }
    -- Every word list counts as loaded already.
    local store = {
        findWord = function(_, letters, word)
            local spelling = known[word:lower()]
            return spelling and signature(spelling) == letters and spelling
                or nil
        end,
        hasLetters = function(_, letters)
            for _, word in ipairs(WORDS) do
                if signature(word) == letters then return true end
            end
            return false
        end,
        isBucketLoaded = function() return true end,
        loadBucketSlice = function() return true end,
    }
    local text_case = {
        apply = function(_, word, mode)
            if mode == "title" then
                return word:sub(1, 1):upper() .. word:sub(2)
            elseif mode == "upper" then
                return word:upper()
            end
            return word
        end,
    }
    local settings = {
        isTrue = function() return false end,
        nilOrTrue = function(_, name)
            return not (options.off and name == "tapless_tap_completions")
        end,
    }
    local controller = InputController:new(context_model, normalization,
        { dbg = noop, warn = noop }, text_case, personal, store, ui_manager,
        settings, nil, nil, usage_model)
    local keyboard = {
        inputbox = newInputBox(),
        swype_mvp_session = InputSession:new(),
        _swypeRefreshCandidateRow = function()
            state.refreshes = state.refreshes + 1
        end,
        _swypeCompleteWord = function(_, prefix, typed, previous_word)
            table.insert(state.asked, { prefix = prefix, typed = typed,
                previous_word = previous_word })
            local found = {}
            for _, word in ipairs(WORDS) do
                local letters = signature(word)
                if letters:sub(1, #prefix) == prefix
                        and word:lower() ~= typed and #found < 4 then
                    found[#found + 1] = { word = word, signature = letters }
                end
            end
            return found
        end,
    }
    function state.type(...)
        for _, key in ipairs({ ... }) do
            controller:addChar(keyboard, key)
        end
    end
    -- Typing pauses: the timers that were waiting run.
    function state.pause()
        local timers = state.timers
        state.timers = {}
        for _, fn in ipairs(timers) do fn() end
    end
    function state.text() return keyboard.inputbox:getText() end
    function state.row()
        local words = {}
        for index, candidate in ipairs(
                keyboard.swype_mvp_session:getCandidates() or {}) do
            words[index] = candidate.output_word or candidate.word
        end
        return table.concat(words, ",")
    end
    function state.pick(index)
        controller:selectCandidate(keyboard,
            keyboard.swype_mvp_session:getCandidates()[index])
    end
    return controller, keyboard, state
end

it("offers words finishing a tapped word once typing pauses", function()
    local _, _, state = setup()
    state.type("t", "h")
    T.eq(state.row(), "", "nothing before the pause")
    state.pause()
    T.eq(state.row(), "the,there,their,then")
    T.eq(state.asked[1].prefix, "th")
end)

it("keeps the completions shown while typing goes on", function()
    local _, _, state = setup()
    state.type("t", "h")
    state.pause()
    local refreshes = state.refreshes
    state.type("e")
    T.eq(state.row(), "the,there,their,then", "not cleared per letter")
    T.eq(state.refreshes, refreshes, "no refresh per letter")
    state.pause()
    T.eq(state.row(), "there,their,then", "brought up to date")
end)

it("lets backspace delete a letter while completions show", function()
    local controller, keyboard, state = setup()
    state.type("t", "h")
    state.pause()
    controller:delChar(keyboard)
    T.eq(state.text(), "t")
end)

it("finishes the word with a picked completion, spaced like a swipe",
        function()
    local _, _, state = setup()
    state.type("h", "e", "l")
    state.pause()
    state.pick(2)
    T.eq(state.text(), "help")
    state.type("m")
    T.eq(state.text(), "help m", "the next word gets its space")
end)

it("keeps the capitals typed", function()
    local _, _, state = setup()
    state.type("T", "h")
    state.pause()
    T.eq(state.row(), "The,There,Their,Then")
    state.pick(2)
    T.eq(state.text(), "There")
end)

it("learns a picked completion after the word before it", function()
    local _, _, state = setup()
    state.type("s", "a", "y", " ", "h", "e")
    state.pause()
    state.pick(1)
    T.eq(state.asked[#state.asked].previous_word, "say")
    T.eq(state.pairs[#state.pairs], "say hello")
    T.eq(state.uses.hello, 2, "a pick counts double")
    state.type(" ")
    state.pause()
    T.eq(state.uses.hello, 2, "not learned again as a tapped word")
end)

it("types nothing from completions the text has moved past", function()
    local _, _, state = setup()
    state.type("t", "h")
    state.pause()
    state.type(" ")
    state.pick(1)
    T.eq(state.text(), "th ", "no word after the space")

    local controller, keyboard, other = setup()
    other.type("t", "h", "e")
    other.pause()
    controller:delChar(keyboard)
    controller:delChar(keyboard)
    other.pick(1)
    T.eq(other.text(), "t", "shorter than what was completed")
end)

it("does not touch a swiped word when a completion is picked", function()
    local controller, keyboard, state = setup()
    controller.applyCandidateCase = noop
    controller:insertBestAndShowCandidates(keyboard, "hlo",
        { { word = "hello" }, { word = "hollow" } })
    state.type("w", "o")
    state.pause()
    state.pick(1)
    T.eq(state.text(), "hello world")
end)

it("takes a blocked completion off the row and types nothing", function()
    local controller, keyboard, state = setup()
    controller.blocked_words = { add = function() return true end }
    state.type("t", "h")
    state.pause()
    controller:blockCandidate(keyboard,
        keyboard.swype_mvp_session:getCandidates()[1])
    T.eq(state.row(), "there,their,then")
    T.eq(state.text(), "th")
end)

it("learns a word tapped out and ended with a space or punctuation",
        function()
    local _, _, state = setup()
    state.type("s", "a", "y", " ", "h", "e", "l", "l", "o", ",")
    T.eq(state.uses.hello, nil, "looked up once the key is handled")
    state.pause()
    T.eq(state.uses.hello, 1)
    T.eq(state.pairs[#state.pairs], "say hello")
    T.eq(state.uses.say, 1)
    T.eq(state.pairs[1], "- say", "no word before the first")
end)

it("does not learn a typo or a swiped word as a tapped one", function()
    local controller, keyboard, state = setup()
    state.type("h", "e", "l", "o", " ")
    state.pause()
    T.eq(state.uses.helo, nil, "not a dictionary word")
    controller.applyCandidateCase = noop
    controller:insertBestAndShowCandidates(keyboard, "wd",
        { { word = "world" } })
    state.type(" ")
    state.pause()
    T.eq(state.uses.world, nil, "a swiped word is learned when committed")
end)

it("learns a word with an apostrophe whole, never its parts", function()
    -- Words too, so only the apostrophe or hyphen stops them.
    for _, word in ipairs({ "don", "re", "well", "known" }) do
        WORDS[#WORDS + 1] = word
    end
    local _, _, state = setup()
    for _ = 1, 4 do table.remove(WORDS) end
    state.type("d", "o", "n", "'", "t", " ", "t", "h", "e", "y", "'", "r",
        "e", " ", "w", "e", "l", "l", "-", "k", "n", "o", "w", "n", " ")
    state.pause()
    T.eq(state.uses["don't"], 1, "the whole word")
    T.eq(state.uses.don, nil)
    T.eq(state.uses.re, nil)
    T.eq(state.uses.well, nil, "a hyphen joins two words into one")
    T.eq(state.uses.known, nil)
end)

it("learns the dictionary's spelling of a tapped word", function()
    local _, _, state = setup()
    state.type("i", "'", "m", " ")
    state.pause()
    T.eq(state.uses["I'm"], 1)
    T.eq(state.uses["i'm"], nil)
end)

it("leaves input method layouts alone", function()
    local _, keyboard, state = setup()
    keyboard.uwrap_func = noop -- set by KOReader for IME layouts
    state.type("h", "e")
    state.pause()
    T.eq(state.row(), "", "no completions")
    state.type("l", "l", "o", " ")
    state.pause()
    T.eq(state.uses.hello, nil, "not learned")
end)

it("offers no completions with the option off", function()
    local _, _, state = setup({ off = true })
    state.type("t", "h")
    state.pause()
    T.eq(state.row(), "")
end)

-- Word lists wa, wb and wc still to read, each taking two slices.
local function slowLists(controller)
    local slices = {}
    local store = controller.dictionary_store
    store.isBucketLoaded = function(_, _, key)
        return key:sub(2) > "c" or (slices[key] or 0) >= 2
    end
    store.loadBucketSlice = function(self, first, last, dictionary)
        local key = first .. last
        if self:isBucketLoaded(dictionary, key) then
            return true
        end
        slices[key] = (slices[key] or 0) + 1
        return slices[key] >= 2
    end
    return slices
end

it("reads a first letter's word lists a slice at a time", function()
    local controller, keyboard, state = setup()
    local slices = slowLists(controller)
    state.type("w")
    state.pause()
    T.eq(slices.wa, 1, "one slice per step")
    state.pause()
    T.eq(slices.wa, 2)
    T.eq(slices.wb, nil)
    state.pause()
    state.pause()
    state.pause()
    state.pause()
    T.eq(slices.wc, 2, "all read")
    keyboard.swype_mvp_closed = true
    state.type("w")
    state.pause()
    T.eq(slices.wa, 2, "nothing once the keyboard closes")
end)

it("stops reading word lists for a language switched away from",
        function()
    local controller, keyboard, state = setup()
    local slices = slowLists(controller)
    keyboard.swype_mvp_dictionary = "en"
    state.type("w")
    state.pause()
    keyboard.swype_mvp_dictionary = "pl"
    state.pause()
    T.eq(slices.wa, 1)
end)

it("does not learn a word the cursor moved to", function()
    local _, keyboard, state = setup()
    state.type("h", "e", "l", "l", "o", " ", "w", "o")
    state.pause()
    keyboard.inputbox.charpos = 6 -- cursor moved to the end of "hello"
    state.type(",")
    state.pause()
    T.eq(state.uses.hello, 1, "only once, when it was typed")
end)

it("forgets a tapped word when the keyboard closes", function()
    local _, keyboard, state = setup()
    state.type("w", "o")
    keyboard.swype_mvp_tapped_word = nil -- as onCloseWidget does
    keyboard.inputbox = newInputBox()
    keyboard.inputbox:addChars("say hello")
    state.type(" ")
    state.pause()
    T.eq(state.uses.hello, nil)
end)

it("completes a word with its apostrophe", function()
    local _, _, state = setup()
    state.type("d", "o", "n", "'")
    state.pause()
    T.eq(state.asked[1].typed, "don'")
    T.eq(state.asked[1].prefix, "don")
    T.eq(state.row(), "don't,done")
    state.pick(1)
    T.eq(state.text(), "don't")

    local _, _, typed_out = setup()
    typed_out.type("d", "o", "n", "t")
    typed_out.pause()
    T.eq(typed_out.row(), "don't", "offered for the letters without it")
end)

it("takes a word with an apostrophe as the previous word", function()
    local _, _, state = setup()
    state.type("I", "'", "m", " ", "h", "e")
    state.pause()
    T.eq(state.asked[#state.asked].previous_word, "i'm")
end)

it("keeps a tapped word through a backspace inside it", function()
    local controller, keyboard, state = setup()
    state.type("h", "e", "l", "p", "x")
    controller:delChar(keyboard)
    state.type(" ")
    state.pause()
    T.eq(state.uses.help, 1)
end)

local engine = Replay.loadPlugin(T.plugin_dir).engine

local function words(results)
    local list = {}
    for index, result in ipairs(results) do list[index] = result.word end
    return table.concat(list, ",")
end

it("reads a word list in slices and keeps it past a cancelled prefetch",
        function()
    local store = Replay.loadPlugin(T.plugin_dir).engine.dictionary_store
    local calls = 0
    repeat
        calls = calls + 1
    until store:loadBucketSlice("q", "n", "en", 5) or calls > 1000
    T.truthy(calls > 1, "more than one slice")
    T.truthy(store:isBucketLoaded("en", "qn"))
    -- A swipe's prefetch read "qs" and was never used by that swipe.
    local job = store:startPrefetch("q", "s", "en")
    while not store:advancePrefetch(job) do end
    store:loadBucketSlice("q", "s", "en", 5)
    store:discardPrefetch({ dictionary = "en", jobs = { qs = job } })
    T.truthy(store:isBucketLoaded("en", "qs"), "kept for completions")
end)

it("completes from the most common words, best first", function()
    local results = engine:completeWord{ prefix = "th", typed = "th" }
    T.eq(#results, 4)
    T.eq(results[1].word, "the")
    for _, result in ipairs(results) do
        T.eq(result.word:sub(1, 2), "th", result.word)
    end
    T.eq(words(engine:completeWord{ prefix = "the", typed = "the" })
        :find("^the,") , nil, "the word as typed is left out")
end)

it("completes contractions with their apostrophes", function()
    T.eq(engine:completeWord{ prefix = "dont", typed = "dont" }[1].word,
        "don't")
    local they = words(engine:completeWord{ prefix = "they", typed = "they" })
    T.truthy(they:find("they're", 1, true), they)
    T.truthy(not they:find("theyre", 1, true), they)
    local store = engine.dictionary_store
    T.truthy(store:hasLetters("dont", "en"), "\"dont\" needs no adding")
    T.eq(store:findWord("im", "i'm", "en"), "I'm")
    T.eq(store:findWord("dont", "dont", "en"), nil)
end)

it("ranks a word that follows the previous word higher", function()
    local plain = engine:completeWord{ prefix = "th", typed = "th" }
    local paired = engine:completeWord{ prefix = "th", typed = "th",
        previous_word = "of",
        context_bonus = function(previous, word)
            return previous == "of" and word == plain[4].word and 5000 or 0
        end }
    T.eq(paired[1].word, plain[4].word)
end)

it("looks beyond the most common words only from three letters",
        function()
    local store = engine.dictionary_store
    -- A rare word: not among the most common words starting with "q".
    local rare = "quercetin"
    local function has(results)
        return words(results):find(rare, 1, true) ~= nil
    end
    T.truthy(not has(engine:completeWord{ prefix = "que", typed = "que",
        limit = 50 }), "common words only")
    T.truthy(not has(engine:completeWord{ prefix = "qu", typed = "qu",
        limit = 400, full = true }), "two letters")
    local full = engine:completeWord{ prefix = "quer", typed = "quer",
        limit = 50, full = true }
    T.truthy(has(full), words(full))
    local only_loaded = Replay.loadPlugin(T.plugin_dir).engine
    T.truthy(not has(only_loaded:completeWord{ prefix = "quer",
        typed = "quer", limit = 50, full = true, only_loaded = true }),
        "not loaded yet")
    T.truthy(store:isBucketLoaded("en", "qn"))
end)
