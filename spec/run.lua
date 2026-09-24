-- Minimal test runner for Tapless logic that does not need a KOReader build.
-- Usage (from the repository root): luajit spec/run.lua
local root = arg and arg[0] and arg[0]:match("^(.*)/spec/run%.lua$") or "."
package.path = root .. "/spec/?.lua;" .. package.path

local T = require("helper")
T.plugin_dir = root .. "/tapless.koplugin"

local specs = {
    "key_adapter_spec",
    "input_controller_spec",
    "concurrent_taps_spec",
    "recognition_spec",
    "recorder_spec",
    "replay_spec",
    "fit_weights_spec",
    "trace_collector_spec",
    "keyboard_geometry_spec",
    "stray_touches_spec",
    "dictionary_controller_spec",
    "blocked_words_spec",
    "personal_dictionary_spec",
    "keyboard_ui_spec",
    "candidate_row_spec",
    "dictionary_registry_spec",
}

for _, name in ipairs(specs) do
    T.run_file(name)
end
os.exit(T.report() and 0 or 1)
