local GeometryReranker = {
    SAMPLE_COUNT = 20,
    RANK_WEIGHT = 1800,
    MAX_SCORE = 2,
}
GeometryReranker.__index = GeometryReranker

local function distance(left, right)
    local dx = left.x - right.x
    local dy = left.y - right.y
    return math.sqrt(dx * dx + dy * dy)
end

local function trimTrace(points)
    if not points or #points < 2 then
        return points or {}
    end
    local first
    local last
    for index, point in ipairs(points) do
        if point.letter or point.letter_index then
            first = first or index
            last = index
        end
    end
    if not first or (first == 1 and last == #points) then
        return points
    end
    local trimmed = {}
    for index = first, last do
        table.insert(trimmed, points[index])
    end
    return trimmed
end

local function resample(points, sample_count)
    if not points or #points < 2 then
        return nil
    end
    local cumulative = { 0 }
    for index = 2, #points do
        cumulative[index] = cumulative[index - 1]
            + distance(points[index - 1], points[index])
    end
    local total_length = cumulative[#points]
    if total_length <= 0 then
        return nil
    end

    local samples = {}
    local segment = 2
    for sample_index = 1, sample_count do
        local target = total_length * (sample_index - 1) / (sample_count - 1)
        while segment < #points and cumulative[segment] < target do
            segment = segment + 1
        end
        local previous_length = cumulative[segment - 1]
        local segment_length = cumulative[segment] - previous_length
        local ratio = segment_length > 0
            and (target - previous_length) / segment_length or 0
        samples[sample_index] = {
            x = points[segment - 1].x
                + (points[segment].x - points[segment - 1].x) * ratio,
            y = points[segment - 1].y
                + (points[segment].y - points[segment - 1].y) * ratio,
        }
    end
    return samples, total_length
end

local function candidatePath(signature, key_centers)
    local points = {}
    local size_total = 0
    for index = 1, #signature do
        local center = key_centers[string.byte(signature, index)]
        if not center then
            return nil
        end
        table.insert(points, { x = center.x, y = center.y })
        size_total = size_total + math.max(1, center.size or 1)
    end
    if #points < 2 then
        return nil
    end
    return points, size_total / #points
end

function GeometryReranker:new()
    return setmetatable({}, self)
end

function GeometryReranker:score(points, signature, key_centers)
    local ideal_points, scale = candidatePath(signature, key_centers or {})
    if not ideal_points then
        return nil
    end
    local actual_samples, actual_length = resample(
        trimTrace(points), self.SAMPLE_COUNT)
    local ideal_samples, ideal_length = resample(
        ideal_points, self.SAMPLE_COUNT)
    if not actual_samples or not ideal_samples then
        return nil
    end

    local distance_total = 0
    for index = 1, self.SAMPLE_COUNT do
        distance_total = distance_total
            + distance(actual_samples[index], ideal_samples[index])
    end
    local shape_score = distance_total / self.SAMPLE_COUNT / scale
    local length_score = math.min(self.MAX_SCORE,
        math.abs(actual_length - ideal_length) / math.max(scale, ideal_length))
    return math.min(self.MAX_SCORE, shape_score * 0.85 + length_score * 0.15)
end

function GeometryReranker:rerank(candidates, trace_info, key_centers, limit)
    limit = limit or #candidates
    if #candidates == 0 then
        return candidates
    end

    local scores = {}
    local score_total = 0
    local score_count = 0
    local points = trace_info and trace_info.points
    if points and #points >= 2 then
        for index, candidate in ipairs(candidates) do
            local signature = candidate.gesture_signature or candidate.signature
            local score = self:score(points, signature, key_centers)
            scores[index] = score
            if score then
                score_total = score_total + score
                score_count = score_count + 1
            end
        end
    end

    if score_count >= 2 then
        local neutral_score = score_total / score_count
        for index, candidate in ipairs(candidates) do
            local score = scores[index] or neutral_score
            candidate.geometry_score = score
            candidate.ranked_score = candidate.ranked_score
                + math.floor(score * self.RANK_WEIGHT + 0.5)
            candidate.geometry_order = index
        end
        table.sort(candidates, function(left, right)
            if left.ranked_score == right.ranked_score then
                return left.geometry_order < right.geometry_order
            end
            return left.ranked_score < right.ranked_score
        end)
    end

    while #candidates > limit do
        table.remove(candidates)
    end
    for _, candidate in ipairs(candidates) do
        candidate.geometry_order = nil
    end
    return candidates
end

return GeometryReranker
