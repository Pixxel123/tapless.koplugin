local Scoring = {
    EDIT_DISTANCE_MAX = 2,
    SCORE_UNIT = 3000,
}
Scoring.__index = Scoring

local ASCII_A = string.byte("a")

function Scoring:new(normalization)
    return setmetatable({
        normalization = assert(normalization),
        warmed = false,
    }, self)
end

function Scoring:buildNextPositions(trace)
    local trace_chars = self.normalization:splitChars(trace)
    local trace_end = #trace_chars + 1
    local next_positions = { [trace_end] = {} }
    local next_for_char = {}
    for code = 1, 26 do
        next_for_char[code] = trace_end
        next_positions[trace_end][code] = trace_end
    end
    for position = #trace_chars, 1, -1 do
        local row = {}
        for code = 1, 26 do
            row[code] = next_for_char[code]
        end
        local code = string.byte(trace_chars[position]) - ASCII_A + 1
        if code >= 1 and code <= 26 then
            next_for_char[code] = position
            row[code] = position
        end
        next_positions[position] = row
    end
    return trace_chars, next_positions
end

function Scoring:editDistance(left, right, max_distance)
    max_distance = max_distance or self.EDIT_DISTANCE_MAX
    local left_len = #left
    local right_len = #right
    if math.abs(left_len - right_len) > max_distance then
        return max_distance + 1
    end

    local infinity = max_distance + 1
    local previous = {}
    for j = 0, math.min(right_len, max_distance) do
        previous[j] = j
    end
    for i = 1, left_len do
        local current = {}
        local from = math.max(1, i - max_distance)
        local to = math.min(right_len, i + max_distance)
        current[0] = i <= max_distance and i or infinity
        local row_min = current[0]
        for j = from, to do
            local cost = string.byte(left, i) == string.byte(right, j) and 0 or 1
            local deletion = (previous[j] or infinity) + 1
            local insertion = (current[j - 1] or infinity) + 1
            local substitution = (previous[j - 1] or infinity) + cost
            local value = math.min(deletion, insertion, substitution)
            if value > infinity then
                value = infinity
            end
            current[j] = value
            row_min = math.min(row_min, value)
        end
        if row_min > max_distance then
            return infinity
        end
        previous = current
    end
    return previous[right_len] or infinity
end

function Scoring:matchScore(candidate, trace_chars, next_positions,
        allow_endpoint_mismatch, trace_letter_points, endpoint_pos, key_centers)
    local trace_len = #trace_chars
    local trace_end = trace_len + 1
    local candidate_len = #candidate
    local pos = 1
    local matched = 0
    local first_match
    local last_match
    local endpoint_mismatch = false
    local geometry_total = 0
    local geometry_measured = 0

    for i = 1, candidate_len do
        local code = string.byte(candidate, i) - ASCII_A + 1
        local row = next_positions and next_positions[pos]
        local found = row and row[code] or nil
        if (not found or found == trace_end) and allow_endpoint_mismatch
                and i == candidate_len and matched == candidate_len - 1
                and trace_len > 0 then
            matched = matched + 1
            last_match = trace_len
            endpoint_mismatch = true
            if trace_letter_points and endpoint_pos and key_centers then
                local target = key_centers[code]
                if target then
                    local dx = endpoint_pos.x - target.x
                    local dy = endpoint_pos.y - target.y
                    local scale = math.max(1, target.size or 1)
                    geometry_total = geometry_total
                        + math.min(2, math.sqrt(dx * dx + dy * dy) / scale)
                    geometry_measured = geometry_measured + 1
                end
            end
            break
        end
        if not found or found == trace_end then
            break
        end
        matched = matched + 1
        first_match = first_match or found
        last_match = found
        if trace_letter_points and key_centers then
            local point = trace_letter_points[found]
            local target = key_centers[code]
            if point and target then
                local dx = point.x - target.x
                local dy = point.y - target.y
                local scale = math.max(1, target.size or 1)
                geometry_total = geometry_total
                    + math.min(2, math.sqrt(dx * dx + dy * dy) / scale)
                geometry_measured = geometry_measured + 1
            end
        end
        pos = found + 1
    end

    local score
    if matched < candidate_len then
        score = 1000 + (candidate_len - matched) * 20
    else
        score = trace_len - candidate_len
        score = score + ((first_match or 1) - 1) * 2
        score = score + (trace_len - (last_match or trace_len)) * 2
        local first_code = string.byte(candidate, 1) - ASCII_A + 1
        local last_code = string.byte(candidate, candidate_len) - ASCII_A + 1
        if string.byte(trace_chars[1]) - ASCII_A + 1 ~= first_code then
            score = score + 6
        end
        if not endpoint_mismatch
                and string.byte(trace_chars[trace_len]) - ASCII_A + 1
                    ~= last_code then
            score = score + 4
        end
        if endpoint_mismatch then
            score = score + 5
        end
    end
    if geometry_measured > 0 then
        score = score + math.min(4,
            math.floor(geometry_total * 2 / geometry_measured + 0.5))
    end
    return score, endpoint_mismatch
end

function Scoring:shortWordEndpointScore(trace, candidate)
    if #candidate > 4 or #trace < #candidate or #trace > 10 then
        return
    end
    local trace_chars = self.normalization:splitChars(trace)
    local candidate_chars = self.normalization:splitChars(candidate)
    if trace_chars[1] ~= candidate_chars[1] then
        return
    end
    local pos = 1
    local matched = 0
    local last_match
    for i = 1, #candidate_chars do
        for j = pos, #trace_chars do
            if trace_chars[j] == candidate_chars[i] then
                matched = matched + 1
                last_match = j
                pos = j + 1
                break
            end
        end
    end
    local missing = #candidate_chars - matched
    if missing > 1 then
        return
    end
    local trailing = #trace_chars - (last_match or #trace_chars)
    if trailing > 1 then
        return
    end
    return math.max(0,
        math.floor(#trace / 2) + missing * 3 + trailing * 2 - 2)
end

function Scoring:scoreEntry(signature, entry, trace_chars, next_positions,
        trace_info, key_centers, allow_endpoint_mismatch, context_bonus)
    local candidate = entry.signature
    local score = self:matchScore(
        candidate,
        trace_chars,
        next_positions,
        allow_endpoint_mismatch,
        trace_info and trace_info.letter_points,
        trace_info and trace_info.endpoint_pos,
        key_centers)
    local endpoint_score = self:shortWordEndpointScore(signature, candidate)
    if endpoint_score and (#candidate <= 3 or (entry.freq or 0) >= 6500) then
        score = math.min(score, math.max(endpoint_score, score - 1))
    end
    if math.abs(#signature - #candidate) <= self.EDIT_DISTANCE_MAX then
        local edit_score = self:editDistance(
            signature, candidate, self.EDIT_DISTANCE_MAX)
        if edit_score <= self.EDIT_DISTANCE_MAX then
            score = math.min(score, edit_score + math.floor(#signature / 2))
        end
    end
    return score,
        score * self.SCORE_UNIT - (entry.freq or 0) - (context_bonus or 0)
end

function Scoring:addCandidate(results, seen, entry, spatial_score,
        ranked_score, limit)
    if seen[entry.word] then
        return
    end
    seen[entry.word] = true
    local candidate = {
        word = entry.word,
        signature = entry.signature,
        spatial_score = spatial_score,
        ranked_score = ranked_score,
    }
    local inserted = false
    for i = 1, #results do
        if ranked_score < results[i].ranked_score then
            table.insert(results, i, candidate)
            inserted = true
            break
        end
    end
    if not inserted then
        table.insert(results, candidate)
    end
    while #results > limit do
        local removed = table.remove(results)
        if removed then
            seen[removed.word] = nil
        end
    end
end

function Scoring:warm()
    if self.warmed then
        return
    end
    local traces = {
        { trace = "nkiuytre", candidates = { "nie", "numer", "nurt" } },
        { trace = "treredsaz", candidates = { "teraz", "tez", "trasa" } },
        { trace = "produktywny", candidates = { "produktywny", "probny", "prosty" } },
    }
    for iteration = 1, 80 do
        local sample = traces[(iteration - 1) % #traces + 1]
        local trace_chars, next_positions = self:buildNextPositions(sample.trace)
        for _, candidate in ipairs(sample.candidates) do
            self:matchScore(candidate, trace_chars, next_positions, false)
            self:shortWordEndpointScore(sample.trace, candidate)
            self:editDistance(sample.trace, candidate, self.EDIT_DISTANCE_MAX)
        end
    end
    self.warmed = true
end

return Scoring
