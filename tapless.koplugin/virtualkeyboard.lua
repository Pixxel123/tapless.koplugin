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
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Font = require("ui/font")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local logger = require("logger")
local time = require("ui/time")
local Screen = Device.screen

local source = debug.getinfo(1, "S").source
local plugin_dir = source:match("^@(.+)/[^/]+%.lua$") or "."
local modules = dofile(plugin_dir .. "/modules.lua")
local function loadModule(name)
    return dofile(plugin_dir .. "/" .. modules[name])
end
local VirtualKeyboard = require("ui/widget/virtualkeyboard")

if VirtualKeyboard._tapless_adapter_installed then
    return VirtualKeyboard
end

local findUpvalue = loadModule("find_upvalue")

local VirtualKey = assert(findUpvalue(VirtualKeyboard.addKeys, "VirtualKey"),
    "Tapless: incompatible KOReader VirtualKeyboard.addKeys")
local CandidateRow = loadModule("candidate_row")
local DictionaryRegistry = loadModule("dictionary_registry")
local DictionaryManager = loadModule("dictionary_manager")
local DictionaryIndex = loadModule("dictionary_index")
local DictionaryStore = loadModule("dictionary_store")
    :new(plugin_dir, DictionaryRegistry, DictionaryIndex, time)
local InputSession = loadModule("input_session")
local Normalization = loadModule("normalization"):new(plugin_dir)
local PersonalDictionary = loadModule("personal_dictionary")
    :new(Normalization, DictionaryIndex)
local BlockedWords = loadModule("blocked_words"):new()
local KeyboardGeometry = loadModule("keyboard_geometry")
    :new(Normalization)
local PrefetchController = loadModule("prefetch_controller")
local Scoring = loadModule("scoring"):new(Normalization)
local GeometryReranker = loadModule("geometry_reranker"):new()
local TraceCollector = loadModule("trace_collector")
local GestureController = loadModule("gesture_controller")
    :new(TraceCollector, UIManager, time, Geom)
local TraceRenderer = loadModule("trace_renderer")
    :new(Screen, UIManager, Geom)
local ContextModel = loadModule("context_model")
    :new(G_reader_settings, "keyboard_swype_mvp_context_counts")
local UsageModel = loadModule("usage_model")
    :new(G_reader_settings, "tapless_word_usage")
local TextCase = loadModule("text_case"):new(Normalization)
local InputController = loadModule("input_controller")
    :new(ContextModel, Normalization, logger, TextCase,
        PersonalDictionary, DictionaryStore, UIManager, G_reader_settings,
        BlockedWords, time, UsageModel)
local DictionaryController = loadModule("dictionary_controller")
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

local KeyAdapter = loadModule("key_adapter")
    :new(Normalization, GestureRange, G_reader_settings)
-- Look this up before Tapless wraps VirtualKey.init.
local VirtualKeyPopup = findUpvalue(VirtualKey.init, "VirtualKeyPopup")
KeyAdapter:install(VirtualKey)

loadModule("concurrent_taps").install{
    input = Device.input,
    gesture_detector = require("device/gesturedetector"),
    ui_manager = UIManager,
    geometry = Geom,
    logger = logger,
    widget_classes = { VirtualKeyboard, VirtualKeyPopup },
}

-- After concurrent_taps: both look up Contact in newContact's upvalues.
loadModule("stray_touches").install{
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

local KeyboardUI = loadModule("keyboard_ui"):new{
    candidate_row = CandidateRow,
    confirm_box = ConfirmBox,
    horizontal_group = HorizontalGroup,
    virtual_key = VirtualKey,
    ui_manager = UIManager,
    gesture_range = GestureRange,
    screen = Screen,
    line_widget = LineWidget,
    geometry = Geom,
    blitbuffer = Blitbuffer,
    size = Size,
}
local OneHanded = loadModule("one_handed")
local PanelButton = loadModule("panel_button"):new{
    input_container = InputContainer,
    frame_container = FrameContainer,
    center_container = CenterContainer,
    image_widget = ImageWidget,
    text_widget = TextWidget,
    font = Font,
    geometry = Geom,
    gesture_range = GestureRange,
    blitbuffer = Blitbuffer,
}
local ResizeFrame = loadModule("resize_frame"):new{
    ui_manager = UIManager,
    input_container = InputContainer,
    overlap_group = OverlapGroup,
    vertical_group = VerticalGroup,
    vertical_span = VerticalSpan,
    horizontal_span = HorizontalSpan,
    gesture_range = GestureRange,
    blitbuffer = Blitbuffer,
    panel_button = PanelButton,
    screen = Screen,
    icon_dir = plugin_dir .. "/icons",
}
local RecognitionEngine = loadModule("recognition_engine")
    :new(DictionaryStore, Scoring, GeometryReranker, PersonalDictionary,
        BlockedWords)

-- Expose dictionary management to the plugin's permanent main-menu entry.
-- Passing nil as the keyboard deliberately clears any stale keyboard
-- reference retained after a text dialog has closed.
function VirtualKeyboard.taplessOpenDictionaryManager()
    DictionaryManager:open(nil, plugin_dir, PersonalDictionary)
end

return loadModule("koreader_adapter"):new{
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
    one_handed = OneHanded:new(G_reader_settings),
    resize_frame = ResizeFrame,
    overlap_group = OverlapGroup,
    virtual_key = VirtualKey,
    virtual_key_popup = VirtualKeyPopup,
    icon_dir = plugin_dir .. "/icons",
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
