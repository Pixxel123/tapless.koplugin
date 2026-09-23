local T = require("helper")
local it = T.it

local KEY = { x = 0, y = 0, w = 100, h = 100 }
local NEXT = { x = 0, y = 100, w = 100, h = 100 }

-- points: { { x, y }, ... }; y >= 100 is on the key below.
local function observe(points)
    local collector = T.load("trace_collector")
    local trace = collector:newTrace()
    for index, point in ipairs(points) do
        local on_next = point[2] >= 100
        collector:addPoint(trace, { x = point[1], y = point[2] },
            on_next and "b" or "a", on_next and NEXT or KEY, index * 20000)
    end
    return collector:snapshot(trace).observations
end

it("treats a back-and-forth scribble on a key as a repeated letter",
        function()
    -- A zig-zag turns left and right in turn, so its turns cancel out.
    local observations = observe({
        { 30, 30 }, { 70, 40 }, { 30, 50 }, { 70, 60 }, { 30, 70 },
        { 70, 80 }, { 70, 150 },
    })
    T.truthy(observations[1].repeat_confidence > 0,
        "confidence " .. observations[1].repeat_confidence)
end)

it("does not treat a single sharp turn as a repeated letter", function()
    -- Right across the key, then a sharp turn down and to the left.
    local observations = observe({
        { 20, 20 }, { 50, 25 }, { 80, 30 }, { 60, 60 }, { 40, 90 },
        { 30, 130 },
    })
    T.eq(observations[1].repeat_confidence, 0)
end)

it("does not treat a slow, jittery pass over a key as a repeated letter",
        function()
    -- Thirty samples 3 px apart crossing the key, wobbling by a pixel.
    local points = {}
    for index = 1, 30 do
        points[index] = { 5 + index * 3, 50 + index % 2 }
    end
    points[#points + 1] = { 50, 150 }
    local observations = observe(points)
    T.eq(observations[1].repeat_confidence, 0)
end)
