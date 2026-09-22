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
