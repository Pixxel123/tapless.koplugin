-- Where each of the plugin's modules lives, relative to the plugin folder.
-- virtualkeyboard.lua, the tests and the replay tools load modules by name
-- through this list.
--
--   koreader/     hooks into KOReader's keyboard and touch handling
--   input/        turning touches and key presses into typed text
--   recognition/  finding the words a swipe or tapped letters could be
--   learning/     the words and word pairs the user keeps
--   dictionary/   reading, installing and managing word lists
--   ui/           drawing the suggestion row, the swipe trail and the
--                 one-handed keyboard's layout
--
-- The word lists themselves are data, in dictionaries/.
return {
    koreader_adapter = "koreader/koreader_adapter.lua",
    key_adapter = "koreader/key_adapter.lua",
    stray_touches = "koreader/stray_touches.lua",
    concurrent_taps = "koreader/concurrent_taps.lua",
    find_upvalue = "koreader/find_upvalue.lua",

    input_controller = "input/input_controller.lua",
    input_session = "input/input_session.lua",
    gesture_controller = "input/gesture_controller.lua",
    trace_collector = "input/trace_collector.lua",
    keyboard_geometry = "input/keyboard_geometry.lua",
    text_case = "input/text_case.lua",

    recognition_engine = "recognition/recognition_engine.lua",
    scoring = "recognition/scoring.lua",
    geometry_reranker = "recognition/geometry_reranker.lua",
    path_shape = "recognition/path_shape.lua",
    shape_channel = "recognition/shape_channel.lua",
    normalization = "recognition/normalization.lua",

    context_model = "learning/context_model.lua",
    usage_model = "learning/usage_model.lua",

    dictionary_store = "dictionary/dictionary_store.lua",
    dictionary_index = "dictionary/dictionary_index.lua",
    dictionary_registry = "dictionary/dictionary_registry.lua",
    dictionary_manager = "dictionary/dictionary_manager.lua",
    dictionary_controller = "dictionary/dictionary_controller.lua",
    prefetch_controller = "dictionary/prefetch_controller.lua",
    personal_dictionary = "dictionary/personal_dictionary.lua",
    blocked_words = "dictionary/blocked_words.lua",
    word_list_file = "dictionary/word_list_file.lua",

    keyboard_ui = "ui/keyboard_ui.lua",
    candidate_row = "ui/candidate_row.lua",
    trace_renderer = "ui/trace_renderer.lua",
    one_handed = "ui/one_handed.lua",
    panel_button = "ui/panel_button.lua",
    resize_frame = "ui/resize_frame.lua",
}
