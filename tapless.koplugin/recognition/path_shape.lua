-- Compares a swipe's path with a word's ideal path through its keys'
-- centres, both resampled to SAMPLE_COUNT evenly spaced points. A word's
-- ideal path is worked out once for the keyboard's layout and kept, so
-- many words can be compared with one swipe cheaply.
local PathShape = {
    SAMPLE_COUNT = 20,
    MAX_SCORE = 2,
    -- The most ideal paths kept: once half as many new ones are kept, the
    -- older half is dropped.
    CACHE_WORDS = 20000,
}
PathShape.__index = PathShape

local function distance(left, right)
    local dx = left.x - right.x
    local dy = left.y - right.y
    return math.sqrt(dx * dx + dy * dy)
end

-- The swipe from its first to its last letter: movement before the first
-- key or after the last is not part of the word.
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

-- points resampled to count evenly spaced points, as one flat list x1, y1,
-- x2, y2, ..., and the path's length; nil for a path without length.
function PathShape.resample(points, count)
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
    for sample_index = 1, count do
        local target = total_length * (sample_index - 1) / (count - 1)
        while segment < #points and cumulative[segment] < target do
            segment = segment + 1
        end
        local previous_length = cumulative[segment - 1]
        local segment_length = cumulative[segment] - previous_length
        local ratio = segment_length > 0
            and (target - previous_length) / segment_length or 0
        samples[2 * sample_index - 1] = points[segment - 1].x
            + (points[segment].x - points[segment - 1].x) * ratio
        samples[2 * sample_index] = points[segment - 1].y
            + (points[segment].y - points[segment - 1].y) * ratio
    end
    return samples, total_length
end

function PathShape:new()
    return setmetatable({
        centers = nil,
        layout = nil,
        words = {},
        older = {},
        size = 0,
    }, self)
end

-- Where the letter keys are, as a string two layouts share only when their
-- keys are in the same places.
local function layoutKey(key_centers)
    local parts = {}
    for code = string.byte("a"), string.byte("z") do
        local center = key_centers[code]
        parts[#parts + 1] = center
            and (center.x .. "," .. center.y .. "," .. (center.size or 1))
            or "-"
    end
    return table.concat(parts, ";")
end

-- Keeps the ideal paths while the keys stay where they were; a new table
-- with the same positions (each swipe gets one) counts as the same layout.
function PathShape:_useLayout(key_centers)
    if rawequal(key_centers, self.centers) then
        return
    end
    self.centers = key_centers
    local layout = layoutKey(key_centers)
    if layout ~= self.layout then
        self.layout = layout
        self.words, self.older, self.size = {}, {}, 0
    end
end

-- The swipe ready to compare: { samples, length }, or nil.
function PathShape:swipe(points)
    local samples, length = PathShape.resample(trimTrace(points),
        self.SAMPLE_COUNT)
    return samples and { samples = samples, length = length } or nil
end

local function build(signature, key_centers)
    local points, size_total = {}, 0
    for index = 1, #signature do
        local center = key_centers[string.byte(signature, index)]
        if not center then
            return false
        end
        points[#points + 1] = { x = center.x, y = center.y }
        size_total = size_total + math.max(1, center.size or 1)
    end
    if #points < 2 then
        return false
    end
    local length = 0
    for index = 2, #points do
        length = length + distance(points[index - 1], points[index])
    end
    if length <= 0 then
        return false
    end
    return {
        points = points,
        length = length,
        scale = size_total / #points,
    }
end

-- The word's ideal path, { length, scale, ... }, or nil when one of its
-- letters has no key. signature: its letters, doubled ones collapsed.
-- Resampling waits for the first score, so a length check is cheap.
function PathShape:ideal(signature, key_centers)
    self:_useLayout(key_centers)
    local kept = self.words[signature]
    if kept == nil then
        kept = self.older[signature]
        if kept == nil then
            kept = build(signature, key_centers)
        end
        self.words[signature] = kept
        self.size = self.size + 1
        if self.size >= self.CACHE_WORDS / 2 then
            self.older, self.words, self.size = self.words, {}, 0
        end
    end
    return kept or nil
end

-- How far the swipe's shape is from the word's: the mean distance between
-- matching samples in key sizes, and a little for the difference in
-- length. 0 is a perfect match; at most MAX_SCORE.
function PathShape:score(swipe, ideal)
    if not ideal.samples then
        ideal.samples = PathShape.resample(ideal.points, self.SAMPLE_COUNT)
        ideal.points = nil
    end
    local a, b = swipe.samples, ideal.samples
    local total = 0
    for index = 1, 2 * self.SAMPLE_COUNT, 2 do
        local dx = a[index] - b[index]
        local dy = a[index + 1] - b[index + 1]
        total = total + math.sqrt(dx * dx + dy * dy)
    end
    local shape = total / self.SAMPLE_COUNT / ideal.scale
    local length = math.min(self.MAX_SCORE,
        math.abs(swipe.length - ideal.length)
            / math.max(ideal.scale, ideal.length))
    return math.min(self.MAX_SCORE, shape * 0.85 + length * 0.15)
end

return PathShape
