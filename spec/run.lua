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
}

for _, name in ipairs(specs) do
    T.run_file(name)
end
os.exit(T.report() and 0 or 1)
