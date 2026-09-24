local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local time = require("ui/time")
local Screen = Device.screen

local source = debug.getinfo(1, "S").source
local plugin_dir = source:match("^@(.+)/[^/]+%.lua$") or "."
local VirtualKeyboard = require("ui/widget/virtualkeyboard")

if VirtualKeyboard._tapless_adapter_installed then
    return VirtualKeyboard
end

local findUpvalue = dofile(plugin_dir .. "/find_upvalue.lua")

local VirtualKey = assert(findUpvalue(VirtualKeyboard.addKeys, "VirtualKey"),
    "Tapless: incompatible KOReader VirtualKeyboard.addKeys")
local CandidateRow = dofile(plugin_dir .. "/candidate_row.lua")
local DictionaryRegistry = dofile(plugin_dir .. "/dictionary_registry.lua")
local DictionaryManager = dofile(plugin_dir .. "/dictionary_manager.lua")
local DictionaryIndex = dofile(plugin_dir .. "/dictionary_index.lua")
local DictionaryStore = dofile(plugin_dir .. "/dictionary_store.lua")
    :new(plugin_dir, DictionaryRegistry, DictionaryIndex, time)
local InputSession = dofile(plugin_dir .. "/input_session.lua")
local Normalization = dofile(plugin_dir .. "/normalization.lua"):new(plugin_dir)
local PersonalDictionary = dofile(plugin_dir .. "/personal_dictionary.lua")
    :new(Normalization, DictionaryIndex)
local BlockedWords = dofile(plugin_dir .. "/blocked_words.lua"):new()
local KeyboardGeometry = dofile(plugin_dir .. "/keyboard_geometry.lua")
    :new(Normalization)
local PrefetchController = dofile(plugin_dir .. "/prefetch_controller.lua")
local Scoring = dofile(plugin_dir .. "/scoring.lua"):new(Normalization)
local GeometryReranker = dofile(plugin_dir .. "/geometry_reranker.lua"):new()
local TraceCollector = dofile(plugin_dir .. "/trace_collector.lua")
local GestureController = dofile(plugin_dir .. "/gesture_controller.lua")
    :new(TraceCollector, UIManager, time, Geom)
local TraceRenderer = dofile(plugin_dir .. "/trace_renderer.lua")
    :new(Screen, UIManager, Geom)
local ContextModel = dofile(plugin_dir .. "/context_model.lua")
    :new(G_reader_settings, "keyboard_swype_mvp_context_counts")
local UsageModel = dofile(plugin_dir .. "/usage_model.lua")
    :new(G_reader_settings, "tapless_word_usage")
local TextCase = dofile(plugin_dir .. "/text_case.lua"):new(Normalization)
local InputController = dofile(plugin_dir .. "/input_controller.lua")
    :new(ContextModel, Normalization, logger, TextCase,
        PersonalDictionary, DictionaryStore, UIManager, G_reader_settings,
        BlockedWords, time, UsageModel)
local DictionaryController = dofile(plugin_dir .. "/dictionary_controller.lua")
    :new{
        plugin_dir = plugin_dir,
        manager = DictionaryManager,
        registry = DictionaryRegistry,
        store = DictionaryStore,
        scoring = Scoring,
        ui_manager = UIManager,
        settings = G_reader_settings,
        logger = logger,
        setting_key = "keyboard_swype_mvp_dictionary",
        enabled_setting_key = "tapless_enabled_dictionaries",
        setup_setting_key = "tapless_language_setup_complete",
        default_profile = Normalization.DEFAULT_PROFILE,
    }

DictionaryManager.language_controller = DictionaryController
DictionaryManager.blocked_words = BlockedWords

local KeyAdapter = dofile(plugin_dir .. "/key_adapter.lua")
    :new(Normalization, GestureRange, G_reader_settings)
-- Look this up before Tapless wraps VirtualKey.init.
local VirtualKeyPopup = findUpvalue(VirtualKey.init, "VirtualKeyPopup")
KeyAdapter:install(VirtualKey)

dofile(plugin_dir .. "/concurrent_taps.lua").install{
    input = Device.input,
    gesture_detector = require("device/gesturedetector"),
    ui_manager = UIManager,
    geometry = Geom,
    logger = logger,
    widget_classes = { VirtualKeyboard, VirtualKeyPopup },
}

-- After concurrent_taps: both look up Contact in newContact's upvalues.
dofile(plugin_dir .. "/stray_touches.lua").install{
    gesture_detector = require("device/gesturedetector"),
    logger = logger,
    swiping = function()
        local stack = UIManager._window_stack or {}
        for index = #stack, 1, -1 do
            local widget = stack[index].widget
            if not widget.toast then
                return widget.isSwypeMvpEnabled ~= nil
                    and widget:isSwypeMvpEnabled()
            end
        end
        return false
    end,
}

local KeyboardUI = dofile(plugin_dir .. "/keyboard_ui.lua"):new{
    candidate_row = CandidateRow,
    confirm_box = ConfirmBox,
    horizontal_group = HorizontalGroup,
    virtual_key = VirtualKey,
    ui_manager = UIManager,
    gesture_range = GestureRange,
    screen = Screen,
}
local RecognitionEngine = dofile(plugin_dir .. "/recognition_engine.lua")
    :new(DictionaryStore, Scoring, GeometryReranker, PersonalDictionary,
        BlockedWords)

-- Expose dictionary management to the plugin's permanent main-menu entry.
-- Passing nil as the keyboard deliberately clears any stale keyboard
-- reference retained after a text dialog has closed.
function VirtualKeyboard.taplessOpenDictionaryManager()
    DictionaryManager:open(nil, plugin_dir, PersonalDictionary)
end

return dofile(plugin_dir .. "/koreader_adapter.lua"):new{
    input_session = InputSession,
    prefetch_controller = PrefetchController,
    dictionary_store = DictionaryStore,
    dictionary_controller = DictionaryController,
    input_controller = InputController,
    keyboard_geometry = KeyboardGeometry,
    keyboard_ui = KeyboardUI,
    recognition_engine = RecognitionEngine,
    gesture_controller = GestureController,
    trace_renderer = TraceRenderer,
    key_adapter = KeyAdapter,
    virtual_key = VirtualKey,
    ui_manager = UIManager,
    settings = G_reader_settings,
    screen = Screen,
    blitbuffer = Blitbuffer,
    bottom_container = BottomContainer,
    center_container = CenterContainer,
    frame_container = FrameContainer,
    geometry = Geom,
    horizontal_group = HorizontalGroup,
    horizontal_span = HorizontalSpan,
    vertical_group = VerticalGroup,
    vertical_span = VerticalSpan,
    size = Size,
    prefetch_batch_size = 96,
    prefetch_work_ms = 3,
}:install(VirtualKeyboard)
