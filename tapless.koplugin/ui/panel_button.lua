-- A plain tap target for the one-handed side panel and resize frame: a
-- white box holding an icon or a word. Unlike a VirtualKey it has no hold,
-- swipe or release handling, so a lift that ends over it does nothing,
-- and its icon can be any size.
local PanelButton = {}
PanelButton.__index = PanelButton

function PanelButton:new(options)
    return setmetatable({
        input_container = assert(options.input_container),
        frame_container = assert(options.frame_container),
        center_container = assert(options.center_container),
        image_widget = assert(options.image_widget),
        text_widget = assert(options.text_widget),
        font = assert(options.font),
        geometry = assert(options.geometry),
        gesture_range = assert(options.gesture_range),
        blitbuffer = assert(options.blitbuffer),
    }, self)
end

-- options: name, width, height, and either icon (a file path) with
-- icon_size or text with font_size and bold; bordersize, radius, and
-- callback (without one, taps are still taken but do nothing).
function PanelButton:create(options)
    local border = options.bordersize or 0
    local content
    if options.icon then
        content = self.image_widget:new{
            file = options.icon,
            width = options.icon_size,
            height = options.icon_size,
            alpha = true,
            is_icon = true,
        }
    else
        content = self.text_widget:new{
            text = options.text,
            face = self.font:getFace("cfont", options.font_size or 20),
            bold = options.bold,
        }
    end
    local frame = self.frame_container:new{
        bordersize = border,
        radius = options.radius,
        padding = 0,
        margin = 0,
        background = self.blitbuffer.COLOR_WHITE,
        self.center_container:new{
            dimen = self.geometry:new{
                w = options.width - 2 * border,
                h = options.height - 2 * border,
            },
            content,
        },
    }
    local button = self.input_container:new{
        dimen = self.geometry:new{
            x = 0, y = 0, w = options.width, h = options.height,
        },
        frame,
    }
    button.tapless_panel_button = options.name
    button.ges_events = {
        TaplessButtonTap = {
            self.gesture_range:new{
                ges = "tap",
                range = function() return button.dimen end,
            },
        },
    }
    button.onTaplessButtonTap = function()
        if options.callback then
            options.callback()
        end
        return true
    end
    return button
end

return PanelButton
