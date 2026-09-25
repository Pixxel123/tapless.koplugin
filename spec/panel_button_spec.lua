local T = require("helper")
local it = T.it

local PanelButton = T.load("panel_button")

-- KOReader widget stand-ins: new returns its options.
local Plain = { new = function(_, options) return options end }

local function newButtons()
    return PanelButton:new{
        input_container = Plain,
        frame_container = Plain,
        center_container = Plain,
        image_widget = Plain,
        text_widget = Plain,
        font = { getFace = function(_, name, size)
            return { name = name, size = size }
        end },
        geometry = Plain,
        gesture_range = T.gesture_range,
        blitbuffer = { COLOR_WHITE = "white" },
    }
end

it("builds a white icon button of the given size", function()
    local button = newButtons():create{
        name = "leave", icon = "/icons/leave.svg", icon_size = 100,
        width = 224, height = 224,
    }
    T.eq(button.tapless_panel_button, "leave", "name")
    T.eq(button.dimen.w, 224, "width")
    T.eq(button.dimen.h, 224, "height")
    local frame = button[1]
    T.eq(frame.background, "white", "background")
    local image = frame[1][1]
    T.eq(image.file, "/icons/leave.svg", "file")
    T.eq(image.width, 100, "icon width")
    T.eq(image.alpha, true, "alpha")
end)

it("builds a bordered word button", function()
    local button = newButtons():create{
        name = "done", text = "Done", bold = true, width = 200, height = 90,
        bordersize = 5,
    }
    local frame = button[1]
    T.eq(frame.bordersize, 5, "border")
    T.eq(frame[1].dimen.w, 190, "inner width")
    local text = frame[1][1]
    T.eq(text.text, "Done", "text")
    T.eq(text.bold, true, "bold")
    T.eq(text.face.name, "cfont", "face")
    T.eq(text.face.size, 20, "font size")
end)

it("runs its callback on a tap and takes the tap", function()
    local tapped = 0
    local button = newButtons():create{
        name = "reset", text = "Reset", width = 10, height = 10,
        callback = function() tapped = tapped + 1 end,
    }
    T.eq(button:onTaplessButtonTap(), true, "taken")
    T.eq(tapped, 1, "callback")
end)

it("takes taps without a callback and listens only on itself", function()
    local button = newButtons():create{
        name = "move", icon = "/icons/move.svg", icon_size = 5,
        width = 10, height = 10,
    }
    T.eq(button:onTaplessButtonTap(), true, "taken")
    local range = button.ges_events.TaplessButtonTap[1]
    T.eq(range.ges, "tap", "gesture")
    T.eq(range.range(), button.dimen, "range")
end)
