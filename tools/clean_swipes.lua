-- Generates clean swipes: a finger moving straight between the centres of a
-- word's keys and pausing briefly on each. They should be easy to
-- recognise, so replaying them with --compare shows whether a change breaks
-- swipes that used to work.
--
-- luajit tools/clean_swipes.lua [--layout SESSION.jsonl] [--dictionary en]
--     [--from RANK] [--count N] > clean.jsonl
--
-- --layout takes the key positions from a recorded session, so the swipes
-- match a real device; without it a Kindle-like layout is used. Words are
-- taken from the dictionary by frequency, starting at RANK (default 1).
local tools_dir = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")
    or "."

local CleanSwipes = {
    -- Distance between pan events in pixels, and time between them and
    -- spent on each key, in microseconds.
    STEP = 12,
    PAN_TIME = 25000,
    KEY_TIME = 60000,
}

-- A Kindle-like layout: 125 x 70 keys, each row shifted half a key.
function CleanSwipes.defaultKeys()
    local keys = {}
    for row, letters in ipairs({ "qwertyuiop", "asdfghjkl", "zxcvbnm" }) do
        for index = 1, #letters do
            keys[#keys + 1] = {
                row = row,
                key = letters:sub(index, index),
                x = (row - 1) * 62 + (index - 1) * 125,
                y = (row - 1) * 70,
                w = 125,
                h = 70,
            }
        end
    end
    return keys
end

-- An attempt record, as the recorder writes them, for swiping word on keys.
-- The finger lands a little off the first key's centre and passes a
-- little off the others, as a real finger does.
function CleanSwipes.attempt(word, keys, dictionary)
    local centers = {}
    for _, key in ipairs(keys) do
        if key.key and not key.candidate then
            centers[key.key] = { key.x + key.w / 2, key.y + key.h / 2 }
        end
    end
    local first = assert(centers[word:sub(1, 1)], "no key for " .. word)
    local start = { math.floor(first[1] + 9), math.floor(first[2] - 6) }
    local events, t = {}, 0
    local px, py = start[1], start[2]
    for index = 2, #word do
        local center = assert(centers[word:sub(index, index)],
            "no key for " .. word)
        local x, y = center[1] + 3, center[2] + 2
        local steps = math.max(1, math.floor(
            math.sqrt((x - px) ^ 2 + (y - py) ^ 2) / CleanSwipes.STEP))
        for step = 1, steps do
            t = t + CleanSwipes.PAN_TIME
            events[#events + 1] = {
                kind = "pan",
                t = t,
                pos = { math.floor(px + (x - px) * step / steps),
                    math.floor(py + (y - py) * step / steps) },
                start = start,
            }
        end
        t = t + CleanSwipes.KEY_TIME
        px, py = x, y
    end
    events[#events + 1] = {
        kind = "pan_release",
        t = t + CleanSwipes.PAN_TIME,
        pos = { math.floor(px), math.floor(py) },
        start = start,
    }
    return {
        type = "attempt",
        target = word,
        dictionary = dictionary or "en",
        keys = keys,
        events = events,
        candidates = {},
    }
end

-- Words of 3 to 10 letters a-z from a bundled dictionary, most frequent
-- first, starting at rank from.
function CleanSwipes.words(plugin_dir, dictionary, from, count)
    local path = plugin_dir .. "/dictionaries/" .. dictionary
        .. "/words.buckets.tsv"
    local ranked, seen = {}, {}
    for line in io.lines(path) do
        local word, _, freq = line:match("^([^\t]+)\t([^\t]+)\t(%d+)")
        if word and not seen[word] and word:match("^[a-z][a-z][a-z]+$")
                and #word <= 10 then
            seen[word] = true
            ranked[#ranked + 1] = { word, tonumber(freq) }
        end
    end
    table.sort(ranked, function(left, right)
        if left[2] ~= right[2] then
            return left[2] > right[2]
        end
        return left[1] < right[1]
    end)
    local words = {}
    for rank = from, math.min(#ranked, from + count - 1) do
        words[#words + 1] = ranked[rank][1]
    end
    return words
end

local function main(args)
    local layout, dictionary, from, count = nil, "en", 1, 1500
    local index = 1
    while index <= #args do
        local option, value = args[index], args[index + 1]
        if option == "--layout" then
            layout = value
        elseif option == "--dictionary" then
            dictionary = value
        elseif option == "--from" then
            from = tonumber(value)
        elseif option == "--count" then
            count = tonumber(value)
        else
            io.stderr:write("usage: luajit tools/clean_swipes.lua "
                .. "[--layout SESSION.jsonl] [--dictionary en] "
                .. "[--from RANK] [--count N]\n")
            os.exit(2)
        end
        index = index + 2
    end
    package.path = tools_dir .. "/?.lua;" .. package.path
    local ok, json = pcall(require, "dkjson")
    if not ok then
        io.stderr:write("dkjson not found: copy koreader/common/dkjson.lua"
            .. " to tools/dkjson.lua\n")
        os.exit(2)
    end
    local keys = CleanSwipes.defaultKeys()
    if layout then
        for line in io.lines(layout) do
            local record = json.decode(line)
            if record and record.type == "attempt" then
                keys = record.keys
                break
            end
        end
    end
    print(json.encode{ type = "start", mode = "words" })
    for _, word in ipairs(CleanSwipes.words(tools_dir .. "/../tapless.koplugin",
            dictionary, from, count)) do
        print(json.encode(CleanSwipes.attempt(word, keys, dictionary)))
    end
end

if arg and arg[0] and arg[0]:match("clean_swipes%.lua$") then
    main(arg)
end

return CleanSwipes
