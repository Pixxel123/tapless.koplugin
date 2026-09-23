local CandidateRow = {}

local function slotText(index, candidates, personal_offer)
    if personal_offer then
 if index == 1 then
            return personal_offer.word
 elseif index == 2 then
            return personal_offer.added and "✓" or "+"
        end
        return " "
    end
 local candidate = candidates[index]
    return candidate and (candidate.output_word or candidate.word) or " "
end

function CandidateRow:create(options)
    local slot_count = options.slot_count or 4
    local horizontal_group = options.HorizontalGroup:new{
        allow_mirroring = false,
    }
    local layout = {}
    local keys = {}
    local candidates = options.candidates or {}
    local candidate_width = math.floor(
        (options.width - (slot_count + 1) * options.key_padding
            - 2 * options.padding) / slot_count)

    for index = 1, slot_count do
 local word = slotText(index, candidates, options.personal_offer)
        local virtual_key = options.VirtualKey:new{
            key = word,
            label = word,
            keyboard = options.keyboard,
            width = candidate_width,
            height = options.height,
        }
        virtual_key.is_swype_candidate = true
        virtual_key.swipe_callback = nil
        -- Holding a suggestion offers to block it; the lift that ends the
        -- hold must not also pick it.
        virtual_key.hold_callback = function()
            local offer = options.get_personal_offer
                and options.get_personal_offer()
            if not offer and options.on_hold_candidate
                    and options.on_hold_candidate(index) then
                virtual_key.ignore_key_release = true
            end
        end
        virtual_key.callback = function()
                local offer = options.get_personal_offer
                    and options.get_personal_offer()
                if offer then
 if index == 2 then
                        options.on_add_personal_word()
                    end
                else
 options.on_select_candidate(index)
            end
        end
        table.insert(keys, virtual_key)
        table.insert(horizontal_group, virtual_key)
        table.insert(layout, virtual_key)
        if index ~= slot_count then
            table.insert(horizontal_group, options.horizontal_padding)
        end
    end

    return {
        widget = horizontal_group,
        layout = layout,
        keys = keys,
    }
end

-- Returns true when a slot's word changed.
function CandidateRow:refresh(options)
    local candidates = options.candidates or {}
    local any_changed = false
    for index, virtual_key in ipairs(options.keys or {}) do
        if not options.only_index or index == options.only_index then
 local word = slotText(index, candidates, options.personal_offer)
            local changed = virtual_key.label ~= word
            virtual_key.key = word
            virtual_key.label = word
            if changed and virtual_key.swype_mvp_label_widget then
                virtual_key.swype_mvp_label_widget:setText(word)
            end
            any_changed = any_changed or changed
            if changed and virtual_key[1] and virtual_key[1].dimen then
                options.UIManager:widgetRepaint(
                    virtual_key[1], virtual_key[1].dimen.x,
                    virtual_key[1].dimen.y)
                options.UIManager:setDirty(
                    nil, options.refresh_type or "ui", virtual_key[1].dimen)
            end
        end
    end
    return any_changed
end

return CandidateRow
