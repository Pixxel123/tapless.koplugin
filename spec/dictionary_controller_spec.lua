local T = require("helper")
local it = T.it

local function newController(installed, stored)
    local DictionaryController = T.load("dictionary_controller")
    stored = stored or {}
    return DictionaryController:new{
        plugin_dir = ".",
        manager = {
            listInstalled = function() return installed end,
        },
        registry = {
            get = function(_, id)
                return { normalization_profile = id .. "-profile" }
            end,
        },
        store = {},
        scoring = {},
        ui_manager = {},
        settings = {
            readSetting = function(_, key) return stored[key] end,
            saveSetting = function(_, key, value) stored[key] = value end,
        },
        logger = {},
        setting_key = "dictionary",
        enabled_setting_key = "enabled",
        setup_setting_key = "setup",
        default_profile = "latin",
    }
end

local function newKeyboard(dictionary)
    local calls = {}
    return {
        swype_mvp_dictionary = dictionary,
        _swypeCommitPendingContext = function()
            calls.committed = true
        end,
        _swypeSetDictionary = function(_, id)
            calls.set = id
            return true
        end,
    }, calls
end

it("leaves the keyboard alone when there is no other language", function()
    local keyboard, calls = newKeyboard("en")
    T.eq(newController({ { id = "en" } }):toggle(keyboard), false)
    T.eq(calls.set, nil)
    T.eq(calls.committed, nil)
end)

it("switches to the next language", function()
    local keyboard, calls = newKeyboard("en")
    T.eq(newController({ { id = "en" }, { id = "pl" } }):toggle(keyboard),
        true)
    T.eq(calls.set, "pl")
end)

it("uses the saved language for personal words without a keyboard",
        function()
    local controller = newController({ { id = "en" }, { id = "de" } },
        { dictionary = "de" })
    local language, profile = controller:personalContext(nil)
    T.eq(language, "de")
    T.eq(profile, "de-profile")
end)

it("uses the keyboard's language for personal words", function()
    local controller = newController({ { id = "en" }, { id = "de" } },
        { dictionary = "de" })
    local keyboard = newKeyboard("en")
    keyboard.swype_mvp_normalization_profile = "latin"
    local language, profile = controller:personalContext(keyboard)
    T.eq(language, "en")
    T.eq(profile, "latin")
end)
