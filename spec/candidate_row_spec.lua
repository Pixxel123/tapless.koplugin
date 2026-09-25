local T = require("helper")
local it = T.it

local function create(on_hold_candidate)
    local built = {}
    local VirtualKey = {}
    function VirtualKey:new(options)
        -- What the key sees while it is being built.
        built[#built + 1] = { is_swype_candidate = options.is_swype_candidate }
        return options
    end
    local horizontal_padding = {}
    local row = T.load("candidate_row"):create{
        HorizontalGroup = { new = function() return {} end },
        VirtualKey = VirtualKey,
        width = 400, height = 40, key_padding = 2, padding = 2,
        horizontal_padding = horizontal_padding,
        candidates = {},
        on_select_candidate = function() end,
        on_hold_candidate = on_hold_candidate,
    }
    return row, built, horizontal_padding
end

it("marks slots as suggestions while they are built", function()
    local _, built = create()
    T.eq(#built, 4)
    for _, key in ipairs(built) do
        T.eq(key.is_swype_candidate, true)
    end
end)

it("lets a slot take taps again once the block dialog closes", function()
    local done
    local row = create(function(_, close)
        done = close
        return true
    end)
    local slot = row.keys[2]
    slot.hold_callback()
    T.eq(slot.ignore_key_release, true, "the lift ending the hold is ignored")
    -- The dialog took the lift; closing it must not leave the flag behind.
    done()
    T.eq(slot.ignore_key_release, nil)
end)

it("keeps the old spacing and slot width without a separator", function()
    local row, _, horizontal_padding = create()
    T.eq(row.layout[1].width, 96)
    T.eq(row.widget[2], horizontal_padding)
end)

-- A stand-in separator: a plain marker table rather than a real line
-- widget, so the group's layout can be inspected directly.
local function lineSeparator(height)
    return { line = true, h = height }
end

local function createWithLines(handle)
    local built = {}
    local VirtualKey = {}
    function VirtualKey:new(options)
        built[#built + 1] = { tapless_bold = options.tapless_bold }
        return options
    end
    local row = T.load("candidate_row"):create{
        HorizontalGroup = { new = function() return {} end },
        VirtualKey = VirtualKey,
        width = 400, height = 40, key_padding = 2, padding = 2,
        horizontal_padding = {},
        candidates = {},
        on_select_candidate = function() end,
        separator = lineSeparator,
        separator_width = 1,
        handle = handle,
    }
    return row, built
end

it("alternates thin lines with the slots", function()
    local row = createWithLines()
    T.eq(#row.widget, 7, "key, line, key, line, key, line, key")
    for _, index in ipairs({ 2, 4, 6 }) do
        T.eq(row.widget[index].line, true)
        T.eq(row.widget[index].h, 40)
    end
end)

it("bolds only the top suggestion", function()
    local _, built = createWithLines()
    T.eq(built[1].tapless_bold, true)
    T.eq(built[2].tapless_bold, nil)
    T.eq(built[3].tapless_bold, nil)
    T.eq(built[4].tapless_bold, nil)
end)

it("puts a left handle first, then a line, and narrows the slots",
        function()
    local row = createWithLines{
        widget = { handle = true }, width = 40, side = "left",
    }
    T.eq(row.widget[1].handle, true)
    T.eq(row.widget[2].line, true)
    T.eq(row.layout[1].width, 87)
end)

it("puts a right handle last", function()
    local row = createWithLines{
        widget = { handle = true }, width = 40, side = "right",
    }
    T.eq(row.widget[#row.widget].handle, true)
end)
