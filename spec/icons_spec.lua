local T = require("helper")
local it = T.it

local function read(name)
    local file = io.open(T.plugin_dir .. "/icons/" .. name .. ".svg", "r")
    if not file then
        return nil
    end
    local text = file:read("*a")
    file:close()
    return text
end

for _, name in ipairs({ "leave", "left", "right", "resize", "move" }) do
    it("ships the " .. name .. " icon as a 24 x 24 SVG", function()
        local text = read(name)
        T.truthy(text, name .. ".svg is missing")
        T.truthy(text:find("<svg", 1, true), "not an SVG")
        T.truthy(text:find('viewBox="0 0 24 24"', 1, true), "viewBox")
        T.truthy(text:find("#000", 1, true), "black ink")
    end)
end
