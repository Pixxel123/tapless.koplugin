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
    local row = T.load("candidate_row"):create{
        HorizontalGroup = { new = function() return {} end },
        VirtualKey = VirtualKey,
        width = 400, height = 40, key_padding = 2, padding = 2,
        horizontal_padding = {},
        candidates = {},
        on_select_candidate = function() end,
        on_hold_candidate = on_hold_candidate,
    }
    return row, built
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
