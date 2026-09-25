local TraceCollector = {}

-- Turns smaller than this, in radians, are left out when looking for a
-- scribble: they are the finger or the sensor wobbling, not a change of
-- direction.
local MIN_SCRIBBLE_TURN = math.pi / 4

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function distance(left, right)
    local dx = left.x - right.x
    local dy = left.y - right.y
    return math.sqrt(dx * dx + dy * dy)
end

local function buildObservations(trace)
    local observations = {}
    for index, letter in ipairs(trace.letters or {}) do
        local dimen = (trace.letter_dimens or {})[index]
        observations[index] = {
            letter = letter,
            center_x = dimen and dimen.x + dimen.w / 2,
            center_y = dimen and dimen.y + dimen.h / 2,
            key_size = dimen and math.max(dimen.w, dimen.h) or 1,
            min_distance = math.huge,
            path_length = 0,
            signed_turn = 0,
            total_turn = 0,
            point_count = 0,
        }
    end

    local points = trace.points or {}
    for point_index, point in ipairs(points) do
        local observation = point.letter_index
            and observations[point.letter_index]
        if observation then
            observation.point_count = observation.point_count + 1
            observation.first_point = observation.first_point or point
            observation.first_point_index = observation.first_point_index
                or point_index
            observation.last_point = point
            observation.last_point_index = point_index
            observation.start_time = observation.start_time or point.time
            observation.end_time = point.time or observation.end_time

            if observation.center_x then
                local dx = point.x - observation.center_x
                local dy = point.y - observation.center_y
                local center_distance = math.sqrt(dx * dx + dy * dy)
                if center_distance < observation.min_distance then
                    observation.min_distance = center_distance
                    observation.anchor_point_index = point_index
                end
            end

            local previous = points[point_index - 1]
            if previous and previous.letter_index == point.letter_index then
                observation.path_length = observation.path_length
                    + distance(previous, point)
            end

            local before = points[point_index - 1]
            local after = points[point_index + 1]
            if before and after
                    and before.letter_index == point.letter_index
                    and after.letter_index == point.letter_index then
                local in_x = point.x - before.x
                local in_y = point.y - before.y
                local out_x = after.x - point.x
                local out_y = after.y - point.y
                local in_length = math.sqrt(in_x * in_x + in_y * in_y)
                local out_length = math.sqrt(out_x * out_x + out_y * out_y)
                if in_length > 0 and out_length > 0 then
                    local cosine = clamp(
                        (in_x * out_x + in_y * out_y)
                            / (in_length * out_length), -1, 1)
                    local turn = math.acos(cosine)
                    local cross = in_x * out_y - in_y * out_x
                    observation.signed_turn = observation.signed_turn
                        + (cross < 0 and -turn or turn)
                    if turn >= MIN_SCRIBBLE_TURN then
                        observation.total_turn = observation.total_turn + turn
                    end
                end
            end
        end
    end

    local duration_total = 0
    local duration_count = 0
    for _, observation in ipairs(observations) do
        if observation.start_time and observation.end_time then
            observation.duration = math.max(
                0, observation.end_time - observation.start_time)
            if observation.duration > 0 then
                duration_total = duration_total + observation.duration
                duration_count = duration_count + 1
            end
        end
    end
    local average_duration = duration_count > 0
        and duration_total / duration_count or 0

    for index, observation in ipairs(observations) do
        local key_size = math.max(1, observation.key_size)
        local proximity = observation.min_distance < math.huge
            and clamp(1 - observation.min_distance / (key_size * 0.65), 0, 1)
            or 0
        local anchor = observation.anchor_point_index
        local turn_strength = 0
        if anchor and points[anchor - 1] and points[anchor + 1] then
            local before = points[anchor - 1]
            local point = points[anchor]
            local after = points[anchor + 1]
            local in_x = point.x - before.x
            local in_y = point.y - before.y
            local out_x = after.x - point.x
            local out_y = after.y - point.y
            local in_length = math.sqrt(in_x * in_x + in_y * in_y)
            local out_length = math.sqrt(out_x * out_x + out_y * out_y)
            if in_length > 0 and out_length > 0 then
                local cosine = clamp(
                    (in_x * out_x + in_y * out_y)
                        / (in_length * out_length), -1, 1)
                turn_strength = (1 - cosine) / 2
            end
        end
        local dwell_strength = average_duration > 0
            and clamp((observation.duration or 0) / average_duration - 1, 0, 1)
            or 0
        observation.intent = clamp(
            0.15 + proximity * 0.45 + turn_strength * 0.30
                + dwell_strength * 0.10,
            0.15, 1)
        if index == 1 or index == #observations then
            observation.intent = math.max(0.9, observation.intent)
        end

        -- A scribble on a key types its letter twice. Count turning in
        -- both directions: a back-and-forth scribble turns left and right
        -- in turn, while a single sharp corner stays under 0.7 of a turn.
        local turn_ratio = observation.total_turn / (2 * math.pi)
        local travel_ratio = observation.path_length / key_size
        if turn_ratio >= 0.7 and travel_ratio >= 0.65 then
            observation.repeat_confidence = clamp(
                (turn_ratio - 0.7) * 2
                    + (travel_ratio - 0.65) * 0.35,
                0, 1)
        else
            observation.repeat_confidence = 0
        end
    end
    return observations
end

function TraceCollector:newTrace()
    return {
        letters = {},
        points = {},
        letter_points = {},
        letter_dimens = {},
        last_letter = nil,
        last_center = nil,
    }
end

function TraceCollector:addPoint(trace, pos, letter, key_dimen, timestamp)
    if not trace or not pos or not pos.x or not pos.y then
        return
    end

    local point = {
        x = math.floor(pos.x),
        y = math.floor(pos.y),
        time = timestamp,
        letter = letter,
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
        table.insert(trace.letter_dimens, key_dimen or false)
        trace.last_letter = letter
        trace.last_center = center or trace.last_center
        point.letter_index = #trace.letters
        result.letter_added = true
    elseif point_added then
        point.letter_index = #trace.letters
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
        points = points,
        observations = buildObservations(trace),
    }
end

return TraceCollector
