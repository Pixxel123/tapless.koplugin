-- Reranks candidates by how well the whole swipe matches each word's ideal
-- path (see path_shape.lua): weight times the shape score is added to the
-- rank.
local GeometryReranker = {
    RANK_WEIGHT = 3089,
}
GeometryReranker.__index = GeometryReranker

function GeometryReranker:new(path_shape)
    return setmetatable({ path_shape = assert(path_shape) }, self)
end

-- The shape score of signature for the swipe through points, or nil.
function GeometryReranker:score(points, signature, key_centers)
    local swipe = self.path_shape:swipe(points)
    local ideal = swipe
        and self.path_shape:ideal(signature, key_centers or {})
    return ideal and self.path_shape:score(swipe, ideal) or nil
end

-- weight: what a shape score of 1 adds to the rank; RANK_WEIGHT unless
-- given.
function GeometryReranker:rerank(candidates, trace_info, key_centers, limit,
        weight)
    limit = limit or #candidates
    weight = weight or self.RANK_WEIGHT
    if #candidates == 0 then
        return candidates
    end

    local scores = {}
    local score_total = 0
    local score_count = 0
    local points = trace_info and trace_info.points
    local swipe = points and #points >= 2 and self.path_shape:swipe(points)
    if swipe then
        for index, candidate in ipairs(candidates) do
            local signature = candidate.gesture_signature or candidate.signature
            local ideal = self.path_shape:ideal(signature, key_centers or {})
            local score = ideal and self.path_shape:score(swipe, ideal) or nil
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
                + math.floor(score * weight + 0.5)
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
