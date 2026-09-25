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
    "world", "would", "word", "say" }

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
    for _, word in ipairs(WORDS) do known[word] = true end
    local personal = {
        prepareWord = function(_, word)
            if #word < 2 then return end
            return word:lower(), word:lower()
        end,
        contains = function() return false end,
    }
    local store = {
        containsWord = function(_, _, word) return known[word] == true end,
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
    local controller = InputController:new(context_model, T.normalization,
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
                if word:sub(1, #prefix) == prefix and word ~= typed:lower()
                        and #found < 4 then
                    found[#found + 1] = { word = word, signature = word }
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
    T.eq(state.uses.hello, 1)
    T.eq(state.pairs[#state.pairs], "say hello")
    T.eq(state.uses.say, 1)
    T.eq(state.pairs[1], "- say", "no word before the first")
end)

it("does not learn a typo or a swiped word as a tapped one", function()
    local controller, keyboard, state = setup()
    state.type("h", "e", "l", "o", " ")
    T.eq(state.uses.helo, nil, "not a dictionary word")
    controller.applyCandidateCase = noop
    controller:insertBestAndShowCandidates(keyboard, "wd",
        { { word = "world" } })
    state.type(" ")
    T.eq(state.uses.world, nil, "a swiped word is learned when committed")
end)

it("does not learn part of a word before an apostrophe or hyphen",
        function()
    WORDS[#WORDS + 1] = "don" -- a word too, so only the apostrophe stops it
    local _, _, state = setup()
    table.remove(WORDS)
    state.type("d", "o", "n", "'", "t", " ")
    T.eq(state.uses.don, nil)
    T.eq(state.uses.t, nil)
    state.type("h", "e", "l", "l", "o", "-")
    T.eq(state.uses.hello, nil)
end)

it("leaves input method layouts alone", function()
    local _, keyboard, state = setup()
    keyboard.uwrap_func = noop -- set by KOReader for IME layouts
    state.type("h", "e")
    state.pause()
    T.eq(state.row(), "", "no completions")
    state.type("l", "l", "o", " ")
    T.eq(state.uses.hello, nil, "not learned")
end)

it("offers no completions with the option off", function()
    local _, _, state = setup({ off = true })
    state.type("t", "h")
    state.pause()
    T.eq(state.row(), "")
end)

it("reads a first letter's word lists one at a time", function()
    local controller, keyboard, state = setup()
    local loaded = {}
    controller.dictionary_store.isBucketLoaded = function(_, _, key)
        return loaded[key] == true or key:sub(2) > "c"
    end
    controller.dictionary_store.loadBucket = function(_, first, last)
        loaded[first .. last] = true
    end
    state.type("w")
    state.pause()
    T.eq(loaded.wa, true)
    T.eq(loaded.wb, nil, "one list per step")
    state.pause()
    state.pause()
    T.eq(loaded.wc, true)
    keyboard.swype_mvp_closed = true
    loaded.wa, loaded.wb, loaded.wc = nil, nil, nil
    state.pause()
    T.eq(loaded.wa, nil, "stops once the keyboard closes")
end)

local engine = Replay.loadPlugin(T.plugin_dir).engine

local function words(results)
    local list = {}
    for index, result in ipairs(results) do list[index] = result.word end
    return table.concat(list, ",")
end

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
