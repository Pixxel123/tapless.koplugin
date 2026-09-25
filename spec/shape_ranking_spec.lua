local T = require("helper")
local it = T.it

local Replay = dofile(T.plugin_dir .. "/../tools/replay.lua")
local CleanSwipes = dofile(T.plugin_dir .. "/../tools/clean_swipes.lua")

-- A clean swipe of word as a recorded attempt, its vertical movement
-- scaled by squash around the middle row.
local function attemptFor(word, squash)
    local keys = CleanSwipes.defaultKeys()
    local attempt = CleanSwipes.attempt(word, keys)
    local middle
    for _, key in ipairs(keys) do
        if key.key == "a" then middle = key.y + key.h / 2 end
    end
    for _, event in ipairs(attempt.events) do
        for _, field in ipairs({ "pos", "start" }) do
            local point = event[field]
            if point then
                event[field] = { point[1],
                    math.floor(middle + (point[2] - middle) * (squash or 1)) }
            end
        end
    end
    return attempt
end

local with = Replay.loadPlugin(T.plugin_dir)
local without = Replay.loadPlugin(T.plugin_dir, { no_shape = true })

local function position(words, word)
    for index, candidate in ipairs(words) do
        if candidate == word then return index end
    end
end

it("leaves swipes crossing few letters to the letters", function()
    Replay.run(with, attemptFor("was"))
    T.eq(with.engine.last_shape.triggered, false)
end)

it("runs on a long swipe", function()
    local result = Replay.run(with, attemptFor("important"))
    T.eq(with.engine.last_shape.triggered, true)
    T.eq(result.words[1], "important")
end)

it("finds a long word swiped flat", function()
    local attempt = attemptFor("important", 0.4)
    local found = Replay.run(with, attempt).words
    local missed = Replay.run(without, attempt).words
    T.truthy(position(found, "important"), table.concat(found, ","))
    T.eq(position(missed, "important"), nil, table.concat(missed, ","))
end)
