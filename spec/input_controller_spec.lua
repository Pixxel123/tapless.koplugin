local T = require("helper")
local it = T.it

local function newController(settings)
    local InputController = T.load("input_controller")
    local logger = { dbg = function() end, warn = function() end }
    local ui_manager = { scheduleIn = function() end }
    local context_model = { commit = function() end }
    settings = settings or {}
    return InputController:new(context_model, T.normalization, logger, {}, {},
        {}, ui_manager, {
            isTrue = function(_, name) return settings[name] == true end,
        })
end

local function newKeyboard(state)
    local key = {
        key = "a",
        onTapSelect = function() state.tapped = (state.tapped or 0) + 1 end,
    }
    return {
        swype_mvp_session = {
            recordShortSignature = function(_, signature)
                state.recorded = signature
            end,
        },
        _swypeKeyAt = function(_, pos)
            if pos then return "a", key end
        end,
        _swypeRefreshCandidateRow = function() end,
    }
end

it("types a one-letter trace as a tap once the finger lifts", function()
    local state = {}
    local handled = newController():finalizeSignature(newKeyboard(state), "a", {
        letter_points = { { x = 1, y = 1 } },
        released = true,
    })
    T.truthy(handled)
    T.eq(state.tapped, 1, "tapped")
    T.eq(state.recorded, nil, "no leftover swipe state")
end)

it("ignores a one-letter trace finalized by the idle timer", function()
    local state = {}
    newController():finalizeSignature(newKeyboard(state), "a", {
        letter_points = { { x = 1, y = 1 } },
    })
    T.eq(state.tapped, nil, "not tapped")
    T.eq(state.recorded, "a", "recorded as before")
end)

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
    function box:text()
        return table.concat(self.charlist)
    end
    return box
end

local function newTypingKeyboard()
    local InputSession = T.load("input_session")
    return {
        inputbox = newInputBox(),
        swype_mvp_session = InputSession:new(),
        _swypeRefreshCandidateRow = function() end,
    }
end

local function typeKeys(controller, keyboard, ...)
    for _, key in ipairs({ ... }) do
        controller:addChar(keyboard, key)
    end
    return keyboard.inputbox:text()
end

local ON = { tapless_double_space_period = true }

it("turns two typed spaces after a word into a period", function()
    local controller = newController(ON)
    T.eq(typeKeys(controller, newTypingKeyboard(), "h", "i", " ", " ", "o"),
        "hi. o")
end)

it("turns a space after a swiped word into a period", function()
    local controller = newController(ON)
    local keyboard = newTypingKeyboard()
    controller.applyCandidateCase = function() end
    controller:insertBestAndShowCandidates(keyboard, "hlo",
        { { word = "hello" }, { word = "hollow" } })
    T.eq(typeKeys(controller, keyboard, " "), "hello. ")
    -- Backspace must now remove one character, not the swiped "hello ".
    controller:delChar(keyboard)
    T.eq(keyboard.inputbox:text(), "hello.")
end)

it("keeps double spaces when the option is off", function()
    T.eq(typeKeys(newController(), newTypingKeyboard(), "h", "i", " ", " "),
        "hi  ")
end)

it("does not add a period after punctuation or a third space", function()
    local controller = newController(ON)
    T.eq(typeKeys(controller, newTypingKeyboard(), "h", "i", "!", " ", " "),
        "hi!  ")
    T.eq(typeKeys(controller, newTypingKeyboard(), "h", " ", " ", " "), "h.  ")
end)

it("does not add a period after the cursor moved or a backspace", function()
    local controller = newController(ON)
    local keyboard = newTypingKeyboard()
    typeKeys(controller, keyboard, "a", "b", " ")
    keyboard.inputbox.charpos = 2 -- cursor moved between a and b
    T.eq(typeKeys(controller, keyboard, " "), "a b ")

    keyboard = newTypingKeyboard()
    typeKeys(controller, keyboard, "a", " ", "b")
    controller:delChar(keyboard)
    T.eq(typeKeys(controller, keyboard, " "), "a  ")
end)

it("leaves input method layouts alone", function()
    local controller = newController(ON)
    local keyboard = newTypingKeyboard()
    keyboard.uwrap_func = function() end -- set by KOReader for IME layouts
    T.eq(typeKeys(controller, keyboard, "a", " ", " "), "a  ")
end)

it("works after non-Latin letters", function()
    local controller = newController(ON)
    T.eq(typeKeys(controller, newTypingKeyboard(), "д", "а", " ", " "), "да. ")
end)

local function swipe(controller, keyboard, ...)
    controller.applyCandidateCase = function() end
    local candidates = {}
    for index, word in ipairs({ ... }) do
        candidates[index] = { word = word }
    end
    controller:insertBestAndShowCandidates(keyboard, "x", candidates)
    return keyboard.inputbox:text()
end

it("puts the space before the next swiped word, not after", function()
    local controller = newController()
    local keyboard = newTypingKeyboard()
    T.eq(swipe(controller, keyboard, "hello"), "hello")
    T.eq(swipe(controller, keyboard, "world"), "hello world")
end)

it("attaches punctuation to a swiped word", function()
    local controller = newController()
    local keyboard = newTypingKeyboard()
    swipe(controller, keyboard, "hello")
    T.eq(typeKeys(controller, keyboard, ","), "hello,")
    T.eq(swipe(controller, keyboard, "world"), "hello, world")
end)

it("starts a new word when a letter is tapped after a swipe", function()
    local controller = newController()
    local keyboard = newTypingKeyboard()
    swipe(controller, keyboard, "hello")
    T.eq(typeKeys(controller, keyboard, "a"), "hello a")
end)

it("types one space when space is tapped after a swipe", function()
    local controller = newController()
    local keyboard = newTypingKeyboard()
    swipe(controller, keyboard, "hello")
    T.eq(typeKeys(controller, keyboard, " "), "hello ")
    T.eq(swipe(controller, keyboard, "world"), "hello world")
end)

it("forgets the pending space once the cursor moves", function()
    local controller = newController()
    local keyboard = newTypingKeyboard()
    swipe(controller, keyboard, "hello")
    keyboard.inputbox.charpos = 1
    T.eq(typeKeys(controller, keyboard, "a"), "ahello")
end)

it("removes a swiped word with one backspace", function()
    local controller = newController()
    local keyboard = newTypingKeyboard()
    keyboard._swypeReset = function() end
    swipe(controller, keyboard, "hi")
    swipe(controller, keyboard, "hello")
    controller:delChar(keyboard)
    T.eq(keyboard.inputbox:text(), "hi ")
    T.eq(swipe(controller, keyboard, "there"), "hi there")
end)

it("keeps the pending space when a suggestion is picked", function()
    local controller = newController()
    controller.context_model.learn = function() end
    local keyboard = newTypingKeyboard()
    swipe(controller, keyboard, "hello", "hollow")
    controller:selectCandidate(keyboard, { word = "hollow" })
    T.eq(keyboard.inputbox:text(), "hollow")
    T.eq(swipe(controller, keyboard, "world"), "hollow world")
end)

it("does not add a period after punctuation typed after a swipe",
        function()
    local controller = newController(ON)
    local keyboard = newTypingKeyboard()
    swipe(controller, keyboard, "hello")
    T.eq(typeKeys(controller, keyboard, ",", " "), "hello, ")
end)

it("clears the suggestions when a space after a swipe becomes a period",
        function()
    local controller = newController(ON)
    local keyboard = newTypingKeyboard()
    local refreshed = 0
    keyboard._swypeRefreshCandidateRow = function()
        refreshed = refreshed + 1
    end
    swipe(controller, keyboard, "hello", "help")
    refreshed = 0
    T.eq(typeKeys(controller, keyboard, " "), "hello. ")
    T.eq(keyboard.swype_mvp_session:getCandidates(), nil)
    T.truthy(refreshed > 0, "suggestion row redrawn")
end)

it("keeps a pending space to the text field it belongs to", function()
    local controller = newController()
    local keyboard = newTypingKeyboard()
    swipe(controller, keyboard, "hello")
    -- Another field of the same dialog, its cursor at the same position.
    keyboard.inputbox = newInputBox()
    keyboard.inputbox:addChars("abcde")
    T.eq(typeKeys(controller, keyboard, "w"), "abcdew")
end)

-- A text box and keyboard around a real input session, for blocking.
local function blockingSetup()
    local InputController = T.load("input_controller")
    local blocked, unblocked = {}, {}
    local blocked_words = {
        add = function(_, language, word)
            table.insert(blocked, language .. ":" .. word)
            return true
        end,
        remove = function(_, language, word)
            table.insert(unblocked, language .. ":" .. word)
            return true
        end,
    }
    local personal = {
        add = function() return true end,
    }
    local controller = InputController:new(
        { learn = function() end, commit = function() end },
        T.normalization, { dbg = function() end, warn = function() end }, {},
        personal, {}, { scheduleIn = function() end },
        { isTrue = function() return false end }, blocked_words)
    local inputbox = { text = "" }
    function inputbox:addChars(chars)
        self.text = self.text .. chars
        self.charpos = #self.text + 1
    end
    function inputbox:delChar()
        self.text = self.text:sub(1, -2)
        self.charpos = #self.text + 1
    end
    function inputbox:getText() return self.text end
    local keyboard = {
        inputbox = inputbox,
        swype_mvp_dictionary = "en",
        swype_mvp_session = T.load("input_session"):new(),
        _swypeReset = function() end,
        _swypeRefreshCandidateRow = function() end,
    }
    local candidates = { { word = "was" }, { word = "wax" } }
    inputbox:addChars(keyboard.swype_mvp_session:recordInsert(
        "wqas", candidates, nil))
    return controller, keyboard, candidates, blocked, unblocked
end

it("replaces the swiped word with the next suggestion when blocked",
        function()
    local controller, keyboard, candidates, blocked = blockingSetup()
    T.eq(keyboard.inputbox.text, "was")
    T.truthy(controller:blockCandidate(keyboard, candidates[1]))
    T.eq(blocked[1], "en:was")
    T.eq(keyboard.inputbox.text, "wax")
end)

it("drops a blocked suggestion from the row", function()
    local controller, keyboard, candidates, blocked = blockingSetup()
    T.truthy(controller:blockCandidate(keyboard, candidates[2]))
    T.eq(blocked[1], "en:wax")
    T.eq(keyboard.inputbox.text, "was", "typed word kept")
    local shown = keyboard.swype_mvp_session:getCandidates()
    T.eq(#shown, 1)
    T.eq(shown[1].word, "was")
end)

it("unblocks a word added to personal words", function()
    local controller, keyboard, _, _, unblocked = blockingSetup()
    keyboard.swype_mvp_session:setPersonalOffer({ word = "bq" })
    T.truthy(controller:addPersonalWord(keyboard))
    T.eq(unblocked[1], "en:bq")
end)
