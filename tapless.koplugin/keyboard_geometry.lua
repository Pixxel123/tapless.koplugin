local KeyboardGeometry = {}
KeyboardGeometry.__index = KeyboardGeometry

function KeyboardGeometry:new(normalization)
    return setmetatable({
        normalization = assert(normalization),
    }, self)
end

function KeyboardGeometry:keyAt(layout, pos, profile)
    if not pos or not layout then
        return
    end
    for _, row in ipairs(layout) do
        for _, key in ipairs(row) do
            if key.dimen and key.dimen:contains(pos) then
                if key.is_swype_candidate then
                    return
                end
                local normalized = self.normalization:normalizeText(
                    key.key or key.label, profile)
                if #normalized == 1 then
                    return normalized, key
                end
                return nil, key
            end
        end
    end
end

function KeyboardGeometry:endpointLetters(layout, pos, exact_last, profile)
    local candidates = {}
    local seen = {}
    if exact_last and #exact_last == 1 then
        table.insert(candidates, exact_last)
        seen[exact_last] = true
    end
    if not pos or not layout then
        return candidates
    end
    local nearby = {}
    for _, row in ipairs(layout) do
        for _, key in ipairs(row) do
            if key.dimen and not key.is_swype_candidate then
                local normalized = self.normalization:normalizeText(
                    key.key or key.label, profile)
                if #normalized == 1 and not seen[normalized] then
                    local center_x = key.dimen.x + key.dimen.w / 2
                    local center_y = key.dimen.y + key.dimen.h / 2
                    local dx = pos.x - center_x
                    local dy = pos.y - center_y
                    table.insert(nearby, {
                        letter = normalized,
                        distance = dx * dx + dy * dy,
                    })
                end
            end
        end
    end
    table.sort(nearby, function(left, right)
        return left.distance < right.distance
    end)
    for index = 1, math.min(2, #nearby) do
        table.insert(candidates, nearby[index].letter)
        seen[nearby[index].letter] = true
    end
    return candidates
end

function KeyboardGeometry:keyCenters(layout, profile)
    local centers = {}
    if not layout then
        return centers
    end
    for _, row in ipairs(layout) do
        for _, key in ipairs(row) do
            if key.dimen and not key.is_swype_candidate then
                local normalized = self.normalization:normalizeText(
                    key.key or key.label, profile)
                local byte = #normalized == 1 and string.byte(normalized)
                if byte and not centers[byte] then
                    centers[byte] = {
                        x = key.dimen.x + key.dimen.w / 2,
                        y = key.dimen.y + key.dimen.h / 2,
                        size = math.max(key.dimen.w, key.dimen.h),
                    }
                end
            end
        end
    end
    return centers
end

return KeyboardGeometry
