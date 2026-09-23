-- Replays recorded Tapless swipe test sessions through a plugin
-- directory's recognition code and reports accuracy.
--
-- luajit tools/replay.lua [--plugin DIR] [--compare DIR] [--misses]
--     SESSION.jsonl...
local tools_dir = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")
    or "."

local function splitToChars(text)
    local chars = {}
    for char in (text or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        chars[#chars + 1] = char
    end
    return chars
end

package.preload["logger"] = package.preload["logger"] or function()
    local noop = function() end
    return { dbg = noop, info = noop, warn = noop, err = noop }
end
package.preload["util"] = package.preload["util"] or function()
    return { splitToChars = splitToChars }
end

local Replay = {}

local function readManifest(path)
    local manifest = {}
    local file = io.open(path, "r")
    if not file then
        return nil
    end
    for line in file:lines() do
        local key, value = line:match("^([^#][^\t]*)\t(.*)$")
        if key then
            manifest[key] = value
        end
    end
    file:close()
    return manifest
end

-- Loads a plugin directory's recognition modules.
function Replay.loadPlugin(plugin_dir)
    local function load(name)
        return dofile(plugin_dir .. "/" .. name .. ".lua")
    end
    local manifests = {}
    local function manifest(id)
        if manifests[id] == nil then
            manifests[id] = readManifest(plugin_dir .. "/dictionaries/"
                .. id .. "/manifest.tsv") or false
        end
        return manifests[id] or nil
    end
    local registry = {
        get = function(_, id)
            local info = manifest(id)
            if not info then
                return nil
            end
            local dir = plugin_dir .. "/dictionaries/" .. id .. "/"
            return {
                id = id,
                data_language = info.data_language or id,
                normalization_profile = info.normalization_profile,
                files = {
                    bucket_data = dir .. "words.buckets.tsv",
                    bucket_index = dir .. "words.buckets.idx",
                    popular_data = dir .. "words.popular.tsv",
                    popular_index = dir .. "words.popular.idx",
                },
            }
        end,
    }
    local normalization = load("normalization"):new(plugin_dir)
    local time_api = {
        now = function() return 0 end,
        ms = function(n) return n * 1000 end,
    }
    local store = load("dictionary_store"):new(plugin_dir, registry,
        load("dictionary_index"), time_api)
    return {
        dir = plugin_dir,
        manifest = manifest,
        normalization = normalization,
        geometry = load("keyboard_geometry"):new(normalization),
        trace_collector = load("trace_collector"),
        gesture_controller = load("gesture_controller"),
        engine = load("recognition_engine"):new(store,
            load("scoring"):new(normalization),
            load("geometry_reranker"):new()),
    }
end

-- Mirrors KOReader's Geom:contains (frontend/ui/geometry.lua): inclusive
-- on every edge, so a point on a shared boundary is inside both keys and
-- keyAt's layout-order scan picks whichever key comes first.
local function contains(self, pos)
    local w, h = pos.w or 0, pos.h or 0
    return self.x <= pos.x and self.y <= pos.y
        and self.x + self.w >= pos.x + w
        and self.y + self.h >= pos.y + h
end

local function buildLayout(keys)
    local layout = {}
    for _, key in ipairs(keys or {}) do
        local row = layout[key.row] or {}
        layout[key.row] = row
        row[#row + 1] = {
            key = key.key,
            label = key.label,
            is_swype_candidate = key.candidate,
            dimen = {
                x = key.x, y = key.y, w = key.w, h = key.h,
                contains = contains,
            },
        }
    end
    local rows = {}
    for index = 1, #layout do
        rows[#rows + 1] = layout[index] or {}
    end
    return rows
end

local function geom(point)
    if point then
        return { x = point[1], y = point[2] }
    end
end

local function noop() end

-- Replays one recorded attempt. Returns { letters, words } or
-- { short = true, letters }.
function Replay.run(plugin, attempt)
    local layout = buildLayout(attempt.keys)
    local info = plugin.manifest(attempt.dictionary or "en") or {}
    local profile = info.normalization_profile
    local clock = 0
    local controller = plugin.gesture_controller:new(plugin.trace_collector,
        { scheduleIn = noop },
        { now = function() return clock end,
            ms = function(n) return n * 1000 end },
        { new = function(_, fields) return fields end })
    local finalized
    local keyboard = {
        isSwypeMvpEnabled = function() return true end,
        _swypeKeyAt = function(_, pos)
            return plugin.geometry:keyAt(layout, pos, profile)
        end,
        _swypeCommitPendingContext = noop,
        _swypeClearCandidateState = noop,
        _swypeClearTracePixels = noop,
        _swypeCancelBucketPrefetch = noop,
        _swypeScheduleBucketPrefetch = noop,
        _swypeDrawTraceSegment = noop,
        _swypeGetPreviousWord = function() return attempt.previous_word end,
        _swypeFinalizeSignature = function(_, signature, trace_info)
            finalized = finalized
                or { signature = signature, trace_info = trace_info }
            return true
        end,
    }
    local function keyFor(letter)
        for _, row in ipairs(layout) do
            for _, key in ipairs(row) do
                if key.key == letter then
                    return key
                end
            end
        end
    end
    for _, event in ipairs(attempt.events or {}) do
        clock = event.t or clock
        local ges = {
            pos = geom(event.pos),
            start_pos = geom(event.start),
            end_pos = geom(event["end"]),
        }
        if event.kind == "pan" then
            controller:onPan(keyboard, ges)
        elseif event.kind == "pan_release" then
            controller:onPanRelease(keyboard, ges)
        else
            controller:onPathRelease(keyboard, ges,
                event.key and keyFor(event.key))
        end
        if finalized then
            break
        end
    end
    if not finalized then
        -- Paused traces are finalized by a timer on the device.
        controller:finalizeTrace(keyboard)
    end
    local signature = finalized and finalized.signature or ""
    if #signature < 2 then
        return { short = true, letters = signature, words = {} }
    end
    local trace_info = finalized.trace_info
    local geometry = plugin.geometry
    local start = trace_info.points and trace_info.points[1]
    -- No context_bonus and no personal dictionary here: replay does not
    -- reproduce the device's saved word-pair learning or personal words
    -- (a stated not-goal), so device accuracy can drift above replay's,
    -- especially over repeated sessions with the same sentence pool.
    local candidates = plugin.engine:pickCandidates{
        signature = signature,
        limit = 4,
        dictionary = attempt.dictionary or "en",
        trace_info = trace_info,
        key_centers = geometry:keyCenters(layout, profile),
        start_letters = geometry.startLetters and function(first)
            return geometry:startLetters(layout, start, first, profile)
        end or nil,
        endpoint_letters = function(last)
            return geometry:endpointLetters(layout, trace_info.endpoint_pos,
                last, profile)
        end,
        normalization_profile = profile,
    }
    local words = {}
    for index, candidate in ipairs(candidates) do
        words[index] = candidate.word
    end
    return { letters = signature, words = words }
end

local function hit(row, limit)
    local target = (row.target or ""):lower()
    for index = 1, math.min(limit, #row.words) do
        if (row.words[index] or ""):lower() == target then
            return true
        end
    end
    return false
end

-- rows: { target, words }. group(row) names the row's group, or nil.
function Replay.summarize(rows, group)
    local function tally()
        return { n = 0, top1 = 0, top4 = 0 }
    end
    local summary = { all = tally(), groups = {}, order = {} }
    local function add(counts, row)
        counts.n = counts.n + 1
        if hit(row, 1) then counts.top1 = counts.top1 + 1 end
        if hit(row, 4) then counts.top4 = counts.top4 + 1 end
    end
    for _, row in ipairs(rows) do
        add(summary.all, row)
        local name = group and group(row)
        if name then
            if not summary.groups[name] then
                summary.groups[name] = tally()
                summary.order[#summary.order + 1] = name
            end
            add(summary.groups[name], row)
        end
    end
    return summary
end

Replay.hit = hit

local function readSessions(paths, json)
    local attempts = {}
    for _, path in ipairs(paths) do
        local mode = "words"
        for line in io.lines(path) do
            local record = json.decode(line)
            if record and record.type == "start" then
                mode = record.mode or mode
            elseif record and record.type == "attempt" and record.target then
                record.mode = mode
                attempts[#attempts + 1] = record
            end
        end
    end
    return attempts
end

local function percent(part, whole)
    return whole > 0 and string.format("%5.1f%%", 100 * part / whole)
        or "    -"
end

local function lengthGroup(row)
    local length = #row.target
    if length <= 3 then return "length 2-3" end
    if length <= 5 then return "length 4-5" end
    if length <= 7 then return "length 6-7" end
    return "length 8+"
end

local function main(args)
    local plugin_dir = tools_dir .. "/../tapless.koplugin"
    local compare_dir, show_misses, paths = nil, false, {}
    local index = 1
    while index <= #args do
        local value = args[index]
        if value == "--plugin" then
            index = index + 1
            plugin_dir = args[index]
        elseif value == "--compare" then
            index = index + 1
            compare_dir = args[index]
        elseif value == "--misses" then
            show_misses = true
        else
            paths[#paths + 1] = value
        end
        index = index + 1
    end
    if #paths == 0 then
        io.stderr:write("usage: luajit tools/replay.lua [--plugin DIR] "
            .. "[--compare DIR] [--misses] SESSION.jsonl...\n")
        os.exit(2)
    end
    package.path = tools_dir .. "/?.lua;" .. package.path
    local ok, json = pcall(require, "dkjson")
    if not ok then
        io.stderr:write("dkjson not found: copy koreader/common/dkjson.lua"
            .. " to tools/dkjson.lua\n")
        os.exit(2)
    end

    local attempts = readSessions(paths, json)
    local plugin = Replay.loadPlugin(plugin_dir)
    local other = compare_dir and Replay.loadPlugin(compare_dir)
    local replayed, device, short = {}, {}, 0
    local changes = { fixed = {}, broke = {} }
    for _, attempt in ipairs(attempts) do
        local result = Replay.run(plugin, attempt)
        if result.short then
            short = short + 1
        else
            local device_words = {}
            for position, candidate in ipairs(attempt.candidates or {}) do
                device_words[position] = candidate.word
            end
            local row = {
                target = attempt.target,
                words = result.words,
                letters = result.letters,
                mode = attempt.mode,
                on_first_key = result.letters:sub(1, 1)
                    == attempt.target:sub(1, 1):lower(),
            }
            replayed[#replayed + 1] = row
            device[#device + 1] = {
                target = attempt.target,
                words = device_words,
                mode = attempt.mode,
                on_first_key = row.on_first_key,
            }
            if other then
                local before = Replay.run(other, attempt)
                before.target = attempt.target
                local was = not before.short and hit(before, 1)
                local now = hit(row, 1)
                if now and not was then
                    table.insert(changes.fixed, { row, before })
                elseif was and not now then
                    table.insert(changes.broke, { row, before })
                end
            end
        end
    end

    local function groupOf(row)
        return row.mode
    end
    local groupings = {
        { "mode", groupOf },
        { "length", lengthGroup },
        { "start", function(row)
            return row.on_first_key and "started on first key"
                or "started elsewhere"
        end },
    }
    print(string.format("%d swipes replayed, %d too short to be swipes",
        #replayed, short))
    print(string.format("%-24s %6s  %7s %7s  %7s %7s", "", "n",
        "replay", "top 4", "device", "top 4"))
    local function line(name, counts, device_counts)
        print(string.format("%-24s %6d  %7s %7s  %7s %7s", name, counts.n,
            percent(counts.top1, counts.n), percent(counts.top4, counts.n),
            percent(device_counts.top1, device_counts.n),
            percent(device_counts.top4, device_counts.n)))
    end
    line("all", Replay.summarize(replayed).all, Replay.summarize(device).all)
    for _, grouping in ipairs(groupings) do
        local ours = Replay.summarize(replayed, grouping[2])
        local theirs = Replay.summarize(device, grouping[2])
        for _, name in ipairs(ours.order) do
            line("  " .. name, ours.groups[name], theirs.groups[name])
        end
    end

    local function describe(row)
        return string.format("%-14s %-16s %s", row.target, row.letters,
            table.concat(row.words, ", "))
    end
    if other then
        print(string.format("\nCompared with %s: %d fixed, %d broken",
            compare_dir, #changes.fixed, #changes.broke))
        for _, pair in ipairs(changes.fixed) do
            print("  fixed  " .. describe(pair[1]) .. "   (was "
                .. table.concat(pair[2].words or {}, ", ") .. ")")
        end
        for _, pair in ipairs(changes.broke) do
            print("  broken " .. describe(pair[1]) .. "   (was "
                .. table.concat(pair[2].words or {}, ", ") .. ")")
        end
    end
    if show_misses then
        print("\nMisses (target, letters crossed, suggestions):")
        for _, row in ipairs(replayed) do
            if not hit(row, 1) then
                print("  " .. describe(row))
            end
        end
    end
end

if arg and arg[0] and arg[0]:match("replay%.lua$") then
    main(arg)
end

return Replay
