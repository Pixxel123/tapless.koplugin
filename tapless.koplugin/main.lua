local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local source = debug.getinfo(1, "S").source
local plugin_dir = source:match("^@(.+)/main%.lua$") or "."
local virtualkeyboard_module = "ui/widget/virtualkeyboard"
local replacement_path = plugin_dir .. "/virtualkeyboard.lua"

-- KOReader loads plugin main files before normal text dialogs are created.
-- Replace the module cache entry so future keyboard instances use the plugin
-- implementation without modifying KOReader's installed core files.
local ok, replacement = pcall(dofile, replacement_path)
if ok and replacement then
    package.loaded[virtualkeyboard_module] = replacement
    logger.info("Tapless: thin VirtualKeyboard adapter loaded")

    -- InputText caches the keyboard class during its own module initialization.
    -- Re-run that binding so an early-loaded InputText also uses Tapless.
    local InputText = require("ui/widget/inputtext")
    InputText.initInputEvents()
    logger.info("Tapless: InputText keyboard binding refreshed")
else
    logger.err("Tapless: failed to load VirtualKeyboard implementation", replacement)
end

local Tapless = WidgetContainer:extend{
    name = "tapless",
    is_doc_only = false,
}

function Tapless:init()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function Tapless:openDictionaryManager()
    if replacement and replacement.taplessOpenDictionaryManager then
        replacement.taplessOpenDictionaryManager()
    else
        logger.err("Tapless: dictionary manager is unavailable")
    end
end

function Tapless:addToMainMenu(menu_items)
    local plugin = self

    menu_items.tapless_settings = {
        text = "Tapless",
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = "Manage dictionaries",
                callback = function()
                    plugin:openDictionaryManager()
                end,
            },
            {
                text = "Keyboard size",
                sub_item_table = {
                    {
                        text = "Same as KOReader",
                        help_text = "Follows KOReader's compact keyboard "
                            .. "setting, and KOReader's key text size when "
                            .. "the text size is Auto.",
                        radio = true,
                        checked_func = function()
                            return G_reader_settings:readSetting(
                                "tapless_keyboard_size") == nil
                        end,
                        callback = function()
                            G_reader_settings:delSetting(
                                "tapless_keyboard_size")
                        end,
                    },
                    {
                        text = "Extra compact",
                        radio = true,
                        checked_func = function()
                            return G_reader_settings:readSetting(
                                "tapless_keyboard_size") == "extra_compact"
                        end,
                        callback = function()
                            G_reader_settings:saveSetting(
                                "tapless_keyboard_size", "extra_compact")
                        end,
                    },
                    {
                        text = "Compact",
                        radio = true,
                        checked_func = function()
                            local value = G_reader_settings:readSetting(
                                "tapless_keyboard_size")
                            return value == "compact"
                        end,
                        callback = function()
                            G_reader_settings:saveSetting(
                                "tapless_keyboard_size", "compact")
                        end,
                    },
                    {
                        text = "Normal",
                        radio = true,
                        checked_func = function()
                            local value = G_reader_settings:readSetting(
                                "tapless_keyboard_size")
                            return value == "normal"
                        end,
                        callback = function()
                            G_reader_settings:saveSetting(
                                "tapless_keyboard_size", "normal")
                        end,
                    },
                    {
                        text = "Large",
                        radio = true,
                        checked_func = function()
                            return G_reader_settings:readSetting(
                                "tapless_keyboard_size") == "large"
                        end,
                        callback = function()
                            G_reader_settings:saveSetting(
                                "tapless_keyboard_size", "large")
                        end,
                    },
                },
            },
            {
                text = "Keyboard text size",
                sub_item_table = {
                    {
                        text = "Auto",
                        radio = true,
                        checked_func = function()
                            return G_reader_settings:readSetting(
                                "tapless_keyboard_font_size", "auto") == "auto"
                        end,
                        callback = function()
                            G_reader_settings:saveSetting(
                                "tapless_keyboard_font_size", "auto")
                        end,
                    },
                    {
                        text = "Small",
                        radio = true,
                        checked_func = function()
                            return G_reader_settings:readSetting(
                                "tapless_keyboard_font_size", "auto") == 18
                        end,
                        callback = function()
                            G_reader_settings:saveSetting(
                                "tapless_keyboard_font_size", 18)
                        end,
                    },
                    {
                        text = "Normal",
                        radio = true,
                        checked_func = function()
                            return G_reader_settings:readSetting(
                                "tapless_keyboard_font_size", "auto") == 22
                        end,
                        callback = function()
                            G_reader_settings:saveSetting(
                                "tapless_keyboard_font_size", 22)
                        end,
                    },
                    {
                        text = "Large",
                        radio = true,
                        checked_func = function()
                            return G_reader_settings:readSetting(
                                "tapless_keyboard_font_size", "auto") == 26
                        end,
                        callback = function()
                            G_reader_settings:saveSetting(
                                "tapless_keyboard_font_size", 26)
                        end,
                    },
                },
            },
            {
                text = "Slide on space to move cursor",
                help_text = "Slide left or right along the space bar to "
                    .. "move the text cursor. Holding space still switches "
                    .. "language.",
                checked_func = function()
                    return G_reader_settings:isTrue("tapless_space_cursor")
                end,
                callback = function()
                    G_reader_settings:flipNilOrFalse("tapless_space_cursor")
                end,
            },
            {
                text = "Double space types a period",
                help_text = "A second space right after a word, or a space "
                    .. "right after a swiped word, becomes \". \". Not used "
                    .. "on Chinese, Japanese, Korean or Vietnamese layouts.",
                checked_func = function()
                    return G_reader_settings:isTrue(
                        "tapless_double_space_period")
                end,
                callback = function()
                    G_reader_settings:flipNilOrFalse(
                        "tapless_double_space_period")
                end,
            },
            {
                text = "Suggest words while typing",
                help_text = "When you pause while tapping out a word, the "
                    .. "suggestion row offers words that finish it. Tap one "
                    .. "to use it.",
                checked_func = function()
                    return G_reader_settings:nilOrTrue(
                        "tapless_tap_completions")
                end,
                callback = function()
                    G_reader_settings:flipNilOrTrue(
                        "tapless_tap_completions")
                end,
            },
        },
    }
end

return Tapless
