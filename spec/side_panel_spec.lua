local T = require("helper")
local it = T.it

local SidePanel = T.load("side_panel")

local Plain = { new = function(_, options) return options end }

local function newPanel()
    return SidePanel:new{
        panel_button = { create = function(_, options) return options end },
        horizontal_group = Plain,
        horizontal_span = Plain,
        vertical_group = Plain,
        vertical_span = Plain,
        icon_dir = "/plugin/icons",
    }
end

local function build(side, target)
    local calls = {}
    local built = newPanel():create{
        width = 453, height = 700, button = 224, key_padding = 2,
        side = side, target = target,
        on_leave = function() calls.leave = true end,
        on_move = function() calls.move = true end,
        on_resize = function() calls.resize = true end,
    }
    return built, calls
end

it("makes leave, arrow and resize buttons as squares", function()
    local built, calls = build("left", "left")
    local names, icons = {}, {}
    for index, button in ipairs(built.buttons) do
        names[index] = button.name
        icons[index] = button.icon
        T.eq(button.width, 224, "width " .. index)
        T.eq(button.height, 224, "height " .. index)
        T.eq(button.icon_size, 100, "icon " .. index)
        button.callback()
    end
    T.eq(table.concat(names, ","), "leave,move,resize", "order")
    T.eq(icons[1], "/plugin/icons/leave.svg", "leave icon")
    T.eq(icons[2], "/plugin/icons/left.svg", "arrow icon")
    T.eq(icons[3], "/plugin/icons/resize.svg", "resize icon")
    T.truthy(calls.leave and calls.move and calls.resize, "callbacks")
end)

it("points the arrow the way the keys will move", function()
    local built = build("left", "right")
    T.eq(built.buttons[2].icon, "/plugin/icons/right.svg")
end)

it("centres the column top to bottom", function()
    local built = build("left", "left")
    local column = built.widget[1]
    T.eq(#column, 7, "spans and buttons")
    T.eq(column[1].width, 12, "top space")
    T.eq(column[2], built.buttons[1], "leave first")
    T.eq(column[3].width, 2, "gap")
    T.eq(column[7].width, 12, "bottom space")
end)

it("pushes the column against the screen edge of its strip", function()
    local left = build("left", "left").widget
    T.eq(left[2].width, 229, "filler after the column")
    local right = build("right", "left").widget
    T.eq(right[1].width, 229, "filler before the column")
    T.eq(#right[2], 7, "then the column")
end)
