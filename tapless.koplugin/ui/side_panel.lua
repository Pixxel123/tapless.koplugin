-- The side panel beside a one-handed keyboard: square icon buttons to
-- leave the mode, move the keys to the other edge, and resize them. The
-- column sits against the screen edge of its strip, centred top to
-- bottom, and keeps its size whatever the keyboard's size.
local SidePanel = {
    ICON_SHARE = 0.45,
}
SidePanel.__index = SidePanel

function SidePanel:new(options)
    return setmetatable({
        panel_button = assert(options.panel_button),
        horizontal_group = assert(options.horizontal_group),
        horizontal_span = assert(options.horizontal_span),
        vertical_group = assert(options.vertical_group),
        vertical_span = assert(options.vertical_span),
        icon_dir = assert(options.icon_dir),
    }, self)
end

-- options: width and height of the strip in px; button, the side of each
-- square; key_padding; side, the screen edge the strip is against;
-- target, the edge the keys would move to; on_leave, on_move, on_resize.
function SidePanel:create(options)
    local size = options.button
    local icon_size = math.floor(size * self.ICON_SHARE)
    local function button(name, icon, callback)
        return self.panel_button:create{
            name = name,
            icon = self.icon_dir .. "/" .. icon .. ".svg",
            icon_size = icon_size,
            width = size,
            height = size,
            callback = callback,
        }
    end
    local leave = button("leave", "leave", options.on_leave)
    local move = button("move", options.target, options.on_move)
    local resize = button("resize", "resize", options.on_resize)

    local gap = options.key_padding
    local spare = math.max(0, options.height - 3 * size - 2 * gap)
    local top = math.floor(spare / 2)
    local column = self.vertical_group:new{ allow_mirroring = false }
    table.insert(column, self.vertical_span:new{ width = top })
    table.insert(column, leave)
    table.insert(column, self.vertical_span:new{ width = gap })
    table.insert(column, move)
    table.insert(column, self.vertical_span:new{ width = gap })
    table.insert(column, resize)
    table.insert(column, self.vertical_span:new{ width = spare - top })

    local filler = self.horizontal_span:new{
        width = math.max(0, options.width - size),
    }
    local row = self.horizontal_group:new{ allow_mirroring = false }
    if options.side == "left" then
        table.insert(row, column)
        table.insert(row, filler)
    else
        table.insert(row, filler)
        table.insert(row, column)
    end
    return { widget = row, buttons = { leave, move, resize } }
end

return SidePanel
