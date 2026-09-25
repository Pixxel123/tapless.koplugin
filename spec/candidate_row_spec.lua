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

it("keeps the key gap between slots", function()
    local row, _, horizontal_padding = create()
    T.eq(row.layout[1].width, 96)
    T.eq(row.widget[2], horizontal_padding)
end)

local function createWithHandle(handle)
    local built = {}
    local VirtualKey = {}
    function VirtualKey:new(options)
        built[#built + 1] = { tapless_bold = options.tapless_bold }
        return options
    end
    local gap = { gap = true }
    local row = T.load("candidate_row"):create{
        HorizontalGroup = { new = function() return {} end },
        VirtualKey = VirtualKey,
        width = 400, height = 40, key_padding = 2, padding = 2,
        horizontal_padding = gap,
        candidates = {},
        on_select_candidate = function() end,
        handle = handle,
    }
    return row, built
end

it("bolds only the top suggestion", function()
    local _, built = createWithHandle()
    T.eq(built[1].tapless_bold, true)
    T.eq(built[2].tapless_bold, nil)
    T.eq(built[3].tapless_bold, nil)
    T.eq(built[4].tapless_bold, nil)
end)

it("puts a left handle first, then a gap, and narrows the slots",
        function()
    local row = createWithHandle{
        widget = { handle = true }, width = 40, side = "left",
    }
    T.eq(row.widget[1].handle, true)
    T.eq(row.widget[2].gap, true)
    T.eq(row.layout[1].width, 86)
end)

it("puts a right handle last, after a gap", function()
    local row = createWithHandle{
        widget = { handle = true }, width = 40, side = "right",
    }
    T.eq(row.widget[#row.widget].handle, true)
    T.eq(row.widget[#row.widget - 1].gap, true)
end)
