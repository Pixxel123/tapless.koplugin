local TraceCollector = {}

function TraceCollector:newTrace()
    return {
        letters = {},
        points = {},
        letter_points = {},
        last_letter = nil,
        last_center = nil,
    }
end

function TraceCollector:addPoint(trace, pos, letter, key_dimen)
    if not trace or not pos or not pos.x or not pos.y then
        return
    end

    local point = {
        x = math.floor(pos.x),
        y = math.floor(pos.y),
    }
    local previous_point = trace.points[#trace.points]
    local point_added = not previous_point
        or math.abs(point.x - previous_point.x) >= 2
        or math.abs(point.y - previous_point.y) >= 2
    if point_added then
        table.insert(trace.points, point)
    end

    local result = {
        point = point,
        previous_point = previous_point,
        point_added = point_added,
        letter_added = false,
        letter_rejected = false,
        active = #trace.letters >= 2,
    }
    if not letter then
        return result
    end

    local center
    if key_dimen then
        center = {
            x = key_dimen.x + math.floor(key_dimen.w / 2),
            y = key_dimen.y + math.floor(key_dimen.h / 2),
        }
    end
    if letter ~= trace.last_letter then
        if center and trace.last_center then
            local dx = center.x - trace.last_center.x
            local dy = center.y - trace.last_center.y
            local minimum_distance = math.max(8,
                math.floor((key_dimen.w or 40) * 0.45))
            if math.sqrt(dx * dx + dy * dy) < minimum_distance then
                result.letter_rejected = true
                return result
            end
        end
        table.insert(trace.letters, letter)
        table.insert(trace.letter_points, point)
        trace.last_letter = letter
        trace.last_center = center or trace.last_center
        result.letter_added = true
    end
    result.active = #trace.letters >= 2
    return result
end

function TraceCollector:snapshot(trace)
    if not trace then
        return
    end
    local points = trace.points or {}
    return {
        signature = table.concat(trace.letters or {}),
        letter_points = trace.letter_points or {},
        endpoint_pos = points[#points],
    }
end

return TraceCollector
