-- Replays recorded Tapless swipe test sessions through a plugin
-- directory's recognition code and reports accuracy, including the swipes
-- that began on a number key and the words the user has learned.
--
-- luajit tools/replay.lua [--plugin DIR] [--compare DIR] [--personal DIR]
--     [--context] [--context-settings FILE] [--usage]
--     [--usage-settings FILE] [--per-session] [--no-learning] [--no-pairs]
--     [--misses] [--losses] [--keep-suspect] SESSION.jsonl...
--
-- The dictionary's word-pair table is used as on the device; --no-pairs
-- leaves it out. The ms column is the recognition engine's mean time per
-- swipe, first loads from disk included.
--
-- --usage-settings and --context-settings read the counts from a KOReader
-- settings file (settings.reader.lua). A session is recorded with learning
-- paused, so replay it with those counts and --no-learning to see what the
-- keyboard did; leave --no-learning out to simulate learning as you go.
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
package.preload["ffi/utf8proc"] = package.preload["ffi/utf8proc"] or
    function()
        return { lowercase_dumb = function(text) return text:lower() end }
    end
package.preload["datastorage"] = package.preload["datastorage"] or
    function()
        return { getDataDir = function() return "." end }
    end

local Replay = {}

-- The device settings keys ContextModel's and UsageModel's counts are saved
-- under.
local CONTEXT_SETTING_KEY = "keyboard_swype_mvp_context_counts"
local USAGE_SETTING_KEY = "tapless_word_usage"

local function deepCopy(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for key, inner in pairs(value) do
        copy[key] = deepCopy(inner)
    end
    return copy
end

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

-- Loads a plugin directory's recognition modules. options.personal_dir,
-- if given, wires up a personal dictionary read from that folder.
-- options.context, if true, gives plugin.context_model: a real
-- ContextModel over an in-memory settings object, seeded with a deep
-- copy of options.context_counts when given. options.usage does the same
-- for plugin.usage_model, seeded from options.usage_counts, but only when
-- the plugin directory has a usage model: an older one has none, and
-- neither learns nor uses word counts. plugin:resetLearning() starts both
-- models over from their seeds.
function Replay.loadPlugin(plugin_dir, options)
    -- A plugin lists where its modules live in modules.lua; older ones
    -- kept them all in the plugin folder.
    local modules_file = io.open(plugin_dir .. "/modules.lua", "r")
    local modules = {}
    if modules_file then
        modules_file:close()
        modules = dofile(plugin_dir .. "/modules.lua")
    end
    local function path(name)
        return plugin_dir .. "/" .. (modules[name] or name .. ".lua")
    end
    local function load(name)
        return dofile(path(name))
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
            local files = {
                bucket_data = dir .. "words.buckets.tsv",
                bucket_index = dir .. "words.buckets.idx",
                popular_data = dir .. "words.popular.tsv",
                popular_index = dir .. "words.popular.idx",
            }
            -- The word-pair table, as the device's registry finds it.
            local pairs_file = not (options and options.no_pairs)
                and io.open(dir .. "words.pairs.tsv", "rb")
            if pairs_file then
                pairs_file:close()
                files.pairs_data = dir .. "words.pairs.tsv"
                files.pairs_index = dir .. "words.pairs.idx"
            end
            return {
                id = id,
                data_language = info.data_language or id,
                normalization_profile = info.normalization_profile,
                files = files,
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
    local personal_dictionary = options and options.personal_dir
        and load("personal_dictionary"):new(normalization,
            load("dictionary_index"), options.personal_dir)
    local function newSettings(key, counts)
        local settings = {
            values = {},
            readSetting = function(self, name, default)
                local value = self.values[name]
                if value == nil then return default end
                return value
            end,
            saveSetting = function(self, name, value)
                self.values[name] = value
            end,
        }
        if counts then
            settings.values[key] = deepCopy(counts)
        end
        return settings
    end
    local function newLearning()
        local context_model, usage_model
        if options and options.context then
            context_model = load("context_model"):new(
                newSettings(CONTEXT_SETTING_KEY, options.context_counts),
                CONTEXT_SETTING_KEY)
        end
        local usage_file = options and options.usage
            and io.open(path("usage_model"), "r")
        if usage_file then
            usage_file:close()
            usage_model = load("usage_model"):new(
                newSettings(USAGE_SETTING_KEY, options.usage_counts),
                USAGE_SETTING_KEY)
        end
        return context_model, usage_model
    end
    -- Plugins from before path_shape.lua build their reranker without one.
    local path_shape_file = io.open(path("path_shape"), "r")
    local path_shape
    if path_shape_file then
        path_shape_file:close()
        path_shape = load("path_shape"):new()
    end
    local plugin = {
        dir = plugin_dir,
        manifest = manifest,
        normalization = normalization,
        geometry = load("keyboard_geometry"):new(normalization),
        trace_collector = load("trace_collector"),
        gesture_controller = load("gesture_controller"),
        engine = load("recognition_engine"):new(store,
            load("scoring"):new(normalization),
            load("geometry_reranker"):new(path_shape),
            personal_dictionary),
    }
    plugin.context_model, plugin.usage_model = newLearning()
    -- options.frozen keeps the counts as seeded: the device pauses learning
    -- while a session is recorded.
    plugin.frozen = options and options.frozen or false
    function plugin:resetLearning()
        self.context_model, self.usage_model = newLearning()
    end
    return plugin
end

-- Mirrors KOReader's Geom:contains (frontend/ui/geometry.lua): inclusive
-- on every edge, so a point on a shared boundary is inside both keys and
-- keyAt's layout-order scan picks whichever key comes first.
-- `pos.w or 0` stands in for Geom's class defaults (w = h = 0) on the
-- bare {x, y} points geom() builds.
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

local function layoutOf(plugin, attempt)
    local info = plugin.manifest(attempt.dictionary or "en") or {}
    return buildLayout(attempt.keys), info.normalization_profile
end

-- Whether pos lies on a number key, from which a swipe counts as starting
-- on the letter key below. A plugin from before number-row starts has no
-- startKeyAt and cannot say.
local function onNumberKey(plugin, layout, profile, pos)
    local geometry = plugin.geometry
    if not (geometry.startKeyAt and pos) then
        return false
    end
    local point = geom(pos)
    return geometry:keyAt(layout, point, profile) == nil
        and geometry:startKeyAt(layout, point, profile) ~= nil
end

-- Whether the swipe began on a number key.
function Replay.startedOnNumberKey(plugin, attempt)
    local event = attempt.events and attempt.events[1]
    local pos = event and (event.start or event.pos)
    if not pos then
        return false
    end
    local layout, profile = layoutOf(plugin, attempt)
    return onNumberKey(plugin, layout, profile, pos)
end

-- The gestures that began on a number key and ended as a swipe or a slide,
-- and so were left to KOReader, which types the digit or its alternate
-- character: { pos, pans, ends }. attempt.gestures holds every gesture
-- dispatched since the previous attempt, the attempt's own last. That one
-- is not left out when the swipe began on a number key: Tapless took it.
function Replay.numberKeyGestures(plugin, attempt)
    local layout, profile = layoutOf(plugin, attempt)
    local groups, group = {}, nil
    for _, gesture in ipairs(attempt.gestures or {}) do
        if gesture.ges == "touch" then
            group = { pos = gesture.pos, pans = 0,
                on_number = onNumberKey(plugin, layout, profile, gesture.pos) }
            groups[#groups + 1] = group
        elseif group and gesture.ges == "pan" then
            group.pans = group.pans + 1
        elseif group then
            group.ends = gesture.ges
        end
    end
    local own = groups[#groups]
    local left = {}
    for _, candidate in ipairs(groups) do
        if candidate.on_number and (candidate.ends == "swipe"
                or candidate.ends == "multiswipe"
                or candidate.ends == "pan_release")
                and not (candidate == own
                    and Replay.startedOnNumberKey(plugin, attempt)) then
            left[#left + 1] = candidate
        end
    end
    return left
end

-- Replays one recorded attempt. Returns { letters, words, personal,
-- bonus, uses, ms }; personal runs parallel to words, and bonus does too
-- when there is a word-pair table or plugin.context_model, uses when
-- plugin.usage_model exists (empty otherwise). ms is the time the
-- recognition engine took. On a signature too short to look up, short =
-- true and words, personal, bonus and uses come back empty.
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
        -- A plugin from before number-row starts has no startKeyAt.
        _swypeStartKeyAt = function(_, pos)
            local lookup = plugin.geometry.startKeyAt
                or plugin.geometry.keyAt
            return lookup(plugin.geometry, layout, pos, profile)
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
        return { short = true, letters = signature, words = {},
            personal = {}, bonus = {}, uses = {} }
    end
    local trace_info = finalized.trace_info
    local geometry = plugin.geometry
    local start = trace_info.points and trace_info.points[1]
    -- context_bonus, as on the device, adds the dictionary's word-pair
    -- table (unless --no-pairs; older plugins have none) to pairs learned
    -- when plugin.context_model exists (--context): learned from swipes
    -- replayed so far this run (Replay.learn), not from the device's own
    -- saved counts, unless seeded with --context-settings. Personal words
    -- come in with --personal.
    local dictionary = attempt.dictionary or "en"
    local store = plugin.engine.dictionary_store
    local pair_bonus = store.pairBonus and function(previous_word, word)
        return store:pairBonus(previous_word, word, dictionary)
    end
    local context_bonus
    if plugin.context_model then
        context_bonus = function(previous_word, word)
            return plugin.context_model:bonus(previous_word, word,
                pair_bonus and pair_bonus(previous_word, word) or 0)
        end
    elseif pair_bonus then
        local package = store:open(dictionary)
        context_bonus = package and package.pairs_index and pair_bonus or nil
    end
    -- word_uses, when plugin.usage_model exists (--usage), counts the
    -- words kept so far this run, or seeded with --usage-settings.
    local word_uses = plugin.usage_model and function(word)
        return plugin.usage_model:uses(word)
    end or nil
    local started = os.clock()
    local candidates = plugin.engine:pickCandidates{
        signature = signature,
        limit = 4,
        dictionary = dictionary,
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
        context_bonus = context_bonus,
        word_uses = word_uses,
    }
    local ms = (os.clock() - started) * 1000
    local words, personal, bonus, uses = {}, {}, {}, {}
    for index, candidate in ipairs(candidates) do
        words[index] = candidate.word
        personal[index] = candidate.personal == true
        if context_bonus then
            bonus[index] = context_bonus(trace_info.previous_word,
                candidate.word)
        end
        if word_uses then
            uses[index] = word_uses(candidate.word)
        end
    end
    return { letters = signature, words = words, personal = personal,
        bonus = bonus, uses = uses, ms = ms }
end

-- "right" or "wrong" when the first suggestion is a word the user has
-- learned, kept as often as the ranking's bonus needs, by whether it was
-- the target; nil otherwise.
function Replay.learnedFirst(result, target)
    local uses = result.uses and result.uses[1]
    if not uses or uses < 2 then
        return nil
    end
    return (result.words[1] or ""):lower() == target:lower() and "right"
        or "wrong"
end

-- How many words plugin's usage model holds, and how many of them the
-- user has kept twice or more; nil when it has no usage model.
function Replay.usageSize(plugin)
    if not plugin.usage_model then
        return nil
    end
    local known, twice = 0, 0
    for _, uses in pairs(plugin.usage_model:getCounts()) do
        known = known + 1
        if uses >= 2 then
            twice = twice + 1
        end
    end
    return known, twice
end

-- How many uses a word picked from the suggestions earns on the device.
Replay.PICK_USES = 2

-- The word the device keeps from attempt, and the uses it earns: nothing
-- for a word deleted again, 2 for a pick, 1 for the first choice left in
-- the text, right or wrong.
function Replay.kept(attempt)
    if attempt.deleted or attempt.short then
        return nil
    end
    if attempt.picked then
        return attempt.picked, Replay.PICK_USES
    end
    if attempt.inserted then
        return attempt.inserted, 1
    end
end

-- Learns what the device learns from attempt: the kept word, as following
-- the previous word in plugin.context_model when there is a model and a
-- previous word, and its uses in plugin.usage_model. No-op otherwise, and
-- for a frozen plugin. Pairs are lowercased; the device learns the chosen
-- candidate in its dictionary casing, so a capitalised dictionary word would
-- get no pair bonus here (moot for now: session words are all lowercase).
function Replay.learn(plugin, attempt)
    local word, uses = Replay.kept(attempt)
    if plugin.frozen or not word then
        return
    end
    local previous_word = attempt.previous_word
    if plugin.context_model and previous_word then
        plugin.context_model:learn(previous_word:lower(), word:lower())
    end
    if plugin.usage_model then
        plugin.usage_model:learn(word, uses)
    end
end

-- The stages a swipe's intended word passes on its way to first place,
-- in order. lossStage names the first one it failed.
Replay.LOSS_STAGES = {
    "not scanned",       -- no bucket searched held it, or no word at all
    "too far",           -- first, quick pass: too few letters crossed
    "cut from shortlist",
    "too far aligned",   -- full alignment: too few letters crossed
    "cut from results",
    "outranked",         -- among the results, but not first
    "first",
}

-- Replays attempt and reports where its intended word was lost, by
-- watching the scoring calls the engine makes.
function Replay.lossStage(plugin, attempt)
    local engine = plugin.engine
    local scoring = engine.scoring
    local reranker = engine.geometry_reranker
    local target = (attempt.target or ""):lower()
    local first_pass, aligned, max_spatial
    local shortlist, results
    local function isTarget(entry)
        return entry.word:lower() == target
    end
    scoring.scoreEntry = function(self, signature, entry, ...)
        local spatial, ranked, near = getmetatable(self).scoreEntry(
            self, signature, entry, ...)
        if isTarget(entry) then
            first_pass = math.min(first_pass or math.huge, spatial)
            max_spatial = math.max(6, #signature)
        end
        return spatial, ranked, near
    end
    scoring.scoreEntryDynamic = function(self, signature, entry, ...)
        local spatial, ranked = getmetatable(self).scoreEntryDynamic(
            self, signature, entry, ...)
        if isTarget(entry) then
            aligned = math.min(aligned or math.huge, spatial)
        end
        return spatial, ranked
    end
    -- The first pass adds candidates with metadata; the final one without.
    scoring.addCandidate = function(self, list, seen, entry, spatial,
            ranked, limit, metadata)
        if metadata then
            shortlist = list
        end
        return getmetatable(self).addCandidate(self, list, seen, entry,
            spatial, ranked, limit, metadata)
    end
    -- The reranker trims the results in place, so note them first.
    if reranker then
        reranker.rerank = function(self, candidates, ...)
            results = {}
            for index, candidate in ipairs(candidates) do
                results[index] = candidate
            end
            return getmetatable(self).rerank(self, candidates, ...)
        end
    end
    local ok, result = pcall(Replay.run, plugin, attempt)
    scoring.scoreEntry = nil
    scoring.scoreEntryDynamic = nil
    scoring.addCandidate = nil
    if reranker then
        reranker.rerank = nil
    end
    if not ok then
        error(result, 0)
    end

    local function holds(list)
        for _, candidate in ipairs(list or {}) do
            if candidate.word:lower() == target then
                return true
            end
        end
        return false
    end
    if result.short then
        return "not scanned"
    elseif (result.words[1] or ""):lower() == target then
        return "first"
    elseif not first_pass then
        return "not scanned"
    elseif first_pass > max_spatial then
        return "too far"
    elseif not holds(shortlist) then
        return "cut from shortlist"
    elseif (aligned or math.huge) > max_spatial then
        return "too far aligned"
    elseif not holds(results) then
        return "cut from results"
    end
    return "outranked"
end

-- Replays one attempt through plugin (and, if given, other, for
-- --compare), computes its loss stage first when wanted, then learns
-- from it last -- into plugin, and other when given -- so a loss
-- stage never sees a pair learned from its own or a later attempt.
-- Returns plugin's result, the loss stage (or nil, unless wanted),
-- and other's result (or nil, unless other is given).
function Replay.replayAttempt(plugin, other, attempt, want_loss_stage)
    local result = Replay.run(plugin, attempt)
    local loss_stage = want_loss_stage
        and Replay.lossStage(plugin, attempt) or nil
    local before = other and Replay.run(other, attempt)
    Replay.learn(plugin, attempt)
    if other then
        Replay.learn(other, attempt)
    end
    return result, loss_stage, before
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

-- 1 / the intended word's place among the suggestions, or 0 when it is
-- not there. Averaged over swipes this is the mean reciprocal rank, which
-- also credits moving a word from fourth place to second.
local function reciprocalRank(row)
    local target = (row.target or ""):lower()
    for index, word in ipairs(row.words or {}) do
        if word:lower() == target then
            return 1 / index
        end
    end
    return 0
end

-- Exact two-sided McNemar test on the swipes a change fixed and broke:
-- the chance of a split at least this uneven if the change made no
-- difference, so that each changed swipe was a fair coin toss.
function Replay.mcnemar(fixed, broken)
    local n = fixed + broken
    local log_half_n = n * math.log(0.5)
    local tail, log_choose = 0, 0
    for i = 0, math.min(fixed, broken) do
        tail = tail + math.exp(log_choose + log_half_n)
        log_choose = log_choose + math.log(n - i) - math.log(i + 1)
    end
    return math.min(1, 2 * tail)
end

-- rows: { target, words, ms }. group(row) names the row's group, or nil.
-- ms, the time each swipe took, is summed over the rows that have it.
function Replay.summarize(rows, group)
    local function tally()
        return { n = 0, top1 = 0, top4 = 0, rr = 0, ms = 0, timed = 0 }
    end
    local summary = { all = tally(), groups = {}, order = {} }
    local function add(counts, row)
        counts.n = counts.n + 1
        if hit(row, 1) then counts.top1 = counts.top1 + 1 end
        if hit(row, 4) then counts.top4 = counts.top4 + 1 end
        counts.rr = counts.rr + reciprocalRank(row)
        if row.ms then
            counts.ms = counts.ms + row.ms
            counts.timed = counts.timed + 1
        end
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

-- Why a recorded attempt should be left out, or nil. Never looks at how
-- the swipe was recognised, which would leave out real misses:
-- keys all at one point were read while the keyboard was being rebuilt;
-- a sentence swipe whose target the text box already ends with was for
-- a later word.
function Replay.auditAttempt(attempt)
    local keys = {}
    for _, key in ipairs(attempt.keys or {}) do
        if not key.candidate then
            keys[#keys + 1] = key
        end
    end
    if #keys > 1 then
        local same = true
        for index = 2, #keys do
            if keys[index].x ~= keys[1].x or keys[index].y ~= keys[1].y then
                same = false
                break
            end
        end
        if same then
            return "keys not laid out"
        end
    end
    local target = (attempt.target or ""):lower()
    local previous = (attempt.previous_word or ""):lower()
    if attempt.mode == "sentences" and #target > 0
            and previous:sub(-#target) == target then
        return "target already typed"
    end
end

-- Attempts in file order, each with its session's mode and the index of
-- its file, and a count of attempts left out by reason.
-- options.keep_suspect keeps them all.
function Replay.readSessions(paths, json, options)
    local keep = options and options.keep_suspect
    local attempts, left_out = {}, {}
    for session, path in ipairs(paths) do
        local mode = "words"
        -- Outcomes name their attempt by id, and ids start again at 1 in
        -- each session.
        local by_id = {}
        for line in io.lines(path) do
            local record = json.decode(line)
            if record and record.type == "start" then
                mode = record.mode or mode
            elseif record and record.type == "attempt" and record.target then
                record.mode = mode
                record.session = session
                if record.id then
                    by_id[record.id] = record
                end
                local reason = not keep and Replay.auditAttempt(record)
                if reason then
                    left_out[reason] = (left_out[reason] or 0) + 1
                else
                    attempts[#attempts + 1] = record
                end
            elseif record and record.type == "outcome"
                    and by_id[record.id] then
                if record.outcome == "picked" then
                    by_id[record.id].picked = record.word
                elseif record.outcome == "deleted" then
                    by_id[record.id].deleted = true
                end
            end
        end
    end
    return attempts, left_out
end

-- "Left out 7 suspect attempts: keys not laid out (1), ...", or nil.
function Replay.describeLeftOut(left_out)
    local reasons, total = {}, 0
    for reason, count in pairs(left_out) do
        reasons[#reasons + 1] = string.format("%s (%d)", reason, count)
        total = total + count
    end
    if total == 0 then
        return nil
    end
    table.sort(reasons)
    return string.format("Left out %d suspect attempts: %s", total,
        table.concat(reasons, ", "))
end

local function percent(part, whole)
    return whole > 0 and string.format("%5.1f%%", 100 * part / whole)
        or "    -"
end

local function reciprocal(sum, count)
    return count > 0 and string.format("%6.3f", sum / count)
        or "     -"
end

local function milliseconds(sum, count)
    return count > 0 and string.format("%5.1f", sum / count) or "    -"
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
    local compare_dir, show_misses, show_losses, paths = nil, false, false,
        {}
    local keep_suspect = false
    local personal_dir
    local use_context, context_settings = false, nil
    local use_usage, usage_settings, per_session = false, nil, false
    local frozen, no_pairs = false, false
    local index = 1
    while index <= #args do
        local value = args[index]
        if value == "--plugin" then
            index = index + 1
            plugin_dir = args[index]
        elseif value == "--compare" then
            index = index + 1
            compare_dir = args[index]
        elseif value == "--personal" then
            index = index + 1
            personal_dir = args[index]
        elseif value == "--context" then
            use_context = true
        elseif value == "--context-settings" then
            index = index + 1
            context_settings = args[index]
        elseif value == "--usage" then
            use_usage = true
        elseif value == "--usage-settings" then
            index = index + 1
            usage_settings = args[index]
        elseif value == "--per-session" then
            per_session = true
        elseif value == "--no-learning" then
            frozen = true
        elseif value == "--no-pairs" then
            no_pairs = true
        elseif value == "--misses" then
            show_misses = true
        elseif value == "--losses" then
            show_losses = true
        elseif value == "--keep-suspect" then
            keep_suspect = true
        else
            paths[#paths + 1] = value
        end
        index = index + 1
    end
    if #paths == 0 then
        io.stderr:write("usage: luajit tools/replay.lua [--plugin DIR] "
            .. "[--compare DIR] [--personal DIR] [--context] "
            .. "[--context-settings FILE] [--usage] "
            .. "[--usage-settings FILE] [--per-session] [--no-learning] "
            .. "[--no-pairs] [--misses] [--losses] [--keep-suspect] "
            .. "SESSION.jsonl...\n")
        os.exit(2)
    end
    package.path = tools_dir .. "/?.lua;" .. package.path
    local ok, json = pcall(require, "dkjson")
    if not ok then
        io.stderr:write("dkjson not found: copy koreader/common/dkjson.lua"
            .. " to tools/dkjson.lua\n")
        os.exit(2)
    end

    local attempts, left_out = Replay.readSessions(paths, json,
        { keep_suspect = keep_suspect })
    local left_out_line = Replay.describeLeftOut(left_out)
    if left_out_line then
        print(left_out_line)
    end
    local context_counts = context_settings
        and dofile(context_settings)[CONTEXT_SETTING_KEY]
    local usage_counts = usage_settings
        and dofile(usage_settings)[USAGE_SETTING_KEY]
    local options = { personal_dir = personal_dir, context = use_context,
        context_counts = context_counts, usage = use_usage,
        usage_counts = usage_counts, frozen = frozen, no_pairs = no_pairs }
    local plugin = Replay.loadPlugin(plugin_dir, options)
    local other = compare_dir and Replay.loadPlugin(compare_dir, options)
    local replayed, device, short = {}, {}, 0
    local changes = { fixed = {}, broke = {} }
    local personal_first, personal_first_before = 0, 0
    local context_first, context_first_before = 0, 0
    -- Whether any swipe had a word-pair bonus to give, learned or from the
    -- dictionary's table.
    local with_pairs = false
    local number_starts, number_left, number_gestures = 0, 0, {}
    local learned_right, learned_wrong = 0, 0
    local known_at_start, twice_at_start = Replay.usageSize(plugin)
    local loss_stages = show_losses and {} or nil
    local session
    for _, attempt in ipairs(attempts) do
        -- Sentences repeat from one session to the next, so what is learned
        -- in one would flatter the next: --per-session starts each over.
        if per_session and session and attempt.session ~= session then
            plugin:resetLearning()
            if other then
                other:resetLearning()
            end
        end
        session = attempt.session
        local number_row = Replay.startedOnNumberKey(plugin, attempt)
        if number_row then
            number_starts = number_starts + 1
        end
        for _, left in ipairs(Replay.numberKeyGestures(plugin, attempt)) do
            number_left = number_left + 1
            number_gestures[#number_gestures + 1] = { attempt = attempt,
                gesture = left }
        end
        local result, loss_stage, before =
            Replay.replayAttempt(plugin, other, attempt, show_losses)
        if show_losses then
            loss_stages[#loss_stages + 1] = { attempt = attempt,
                stage = loss_stage }
        end
        if result.short then
            short = short + 1
        else
            local target = attempt.target:lower()
            if result.personal[1] and (result.words[1] or ""):lower()
                    ~= target then
                personal_first = personal_first + 1
            end
            with_pairs = with_pairs or result.bonus[1] ~= nil
            if result.bonus[1] and result.bonus[1] > 0
                    and (result.words[1] or ""):lower() ~= target then
                context_first = context_first + 1
            end
            local learned = Replay.learnedFirst(result, attempt.target)
            if learned == "right" then
                learned_right = learned_right + 1
            elseif learned == "wrong" then
                learned_wrong = learned_wrong + 1
            end
            local device_words = {}
            for position, candidate in ipairs(attempt.candidates or {}) do
                device_words[position] = candidate.word
            end
            local row = {
                target = attempt.target,
                words = result.words,
                letters = result.letters,
                ms = result.ms,
                mode = attempt.mode,
                number_row = number_row,
                on_first_key = result.letters:sub(1, 1)
                    == attempt.target:sub(1, 1):lower(),
            }
            replayed[#replayed + 1] = row
            device[#device + 1] = {
                target = attempt.target,
                words = device_words,
                mode = attempt.mode,
                number_row = number_row,
                on_first_key = row.on_first_key,
            }
            if other then
                before.target = attempt.target
                if not before.short and before.personal[1]
                        and (before.words[1] or ""):lower() ~= target then
                    personal_first_before = personal_first_before + 1
                end
                if not before.short and before.bonus[1]
                        and before.bonus[1] > 0
                        and (before.words[1] or ""):lower() ~= target then
                    context_first_before = context_first_before + 1
                end
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
        -- Only these swipes are grouped, so the row shows when there are any.
        { "number row", function(row)
            return row.number_row and "started on a number key" or nil
        end },
    }
    print(string.format("%d swipes replayed, %d too short to be swipes",
        #replayed, short))
    print(string.format("%-24s %6s  %7s %7s %6s %5s  %7s %7s", "", "n",
        "replay", "top 4", "MRR", "ms", "device", "top 4"))
    local function line(name, counts, device_counts)
        print(string.format("%-24s %6d  %7s %7s %s %s  %7s %7s", name,
            counts.n, percent(counts.top1, counts.n),
            percent(counts.top4, counts.n), reciprocal(counts.rr, counts.n),
            milliseconds(counts.ms, counts.timed),
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
    if personal_dir then
        if other then
            print(string.format("\nPersonal words put first over the "
                .. "intended word: %d (was %d)", personal_first,
                personal_first_before))
        else
            print(string.format("\nPersonal words put first over the "
                .. "intended word: %d", personal_first))
        end
    end
    if use_context or with_pairs then
        if other then
            print(string.format("\nWords with a word-pair bonus put first "
                .. "over the intended word: %d (was %d)", context_first,
                context_first_before))
        else
            print(string.format("\nWords with a word-pair bonus put first "
                .. "over the intended word: %d", context_first))
        end
    end
    if other then
        print("Times (ms) are this plugin's, and only rough: two plugins "
            .. "in one LuaJIT process slow each other down. Time each on "
            .. "its own to compare them.")
    end
    if number_starts > 0 or number_left > 0 then
        print(string.format("\nSwipes that began on a number key: %d taken "
            .. "as word swipes, %d left to KOReader (a digit or its "
            .. "alternate character typed)", number_starts, number_left))
    end
    if plugin.usage_model then
        if known_at_start > 0 then
            print(string.format("\nWord counts at the start: %d words, %d "
                .. "kept twice or more", known_at_start, twice_at_start))
        end
        print(string.format("Learned words put first: %d right, %d wrong",
            learned_right, learned_wrong))
    end

    local function describe(row)
        return string.format("%-14s %-16s %s", row.target, row.letters,
            table.concat(row.words, ", "))
    end
    if other then
        print(string.format(
            "\nCompared with %s: %d fixed, %d broken (McNemar p = %.2g)",
            compare_dir, #changes.fixed, #changes.broke,
            Replay.mcnemar(#changes.fixed, #changes.broke)))
        for _, pair in ipairs(changes.fixed) do
            print("  fixed  " .. describe(pair[1]) .. "   (was "
                .. table.concat(pair[2].words or {}, ", ") .. ")")
        end
        for _, pair in ipairs(changes.broke) do
            print("  broken " .. describe(pair[1]) .. "   (was "
                .. table.concat(pair[2].words or {}, ", ") .. ")")
        end
    end
    if show_losses then
        local counts, groups = {}, {}
        for _, entry in ipairs(loss_stages) do
            local stage = entry.stage
            local group = lengthGroup(entry.attempt)
            counts[stage] = (counts[stage] or 0) + 1
            groups[group] = groups[group] or {}
            groups[group][stage] = (groups[group][stage] or 0) + 1
        end
        local names = { "length 2-3", "length 4-5", "length 6-7",
            "length 8+" }
        print("\nWhere intended words were lost:")
        print(string.format("  %-20s %5s %11s %11s %11s %11s", "", "all",
            unpack(names)))
        for _, stage in ipairs(Replay.LOSS_STAGES) do
            local cells = {}
            for index, name in ipairs(names) do
                cells[index] = (groups[name] or {})[stage] or 0
            end
            print(string.format("  %-20s %5d %11d %11d %11d %11d", stage,
                counts[stage] or 0, unpack(cells)))
        end
    end
    if show_misses then
        print("\nMisses (target, letters crossed, suggestions):")
        for _, row in ipairs(replayed) do
            if not hit(row, 1) then
                print("  " .. describe(row))
            end
        end
        if #number_gestures > 0 then
            print("\nNumber-key gestures left to KOReader (word of the "
                .. "swipe recorded after them, how they ended):")
            for _, entry in ipairs(number_gestures) do
                local left = entry.gesture
                print(string.format("  %-14s %s after %d pans, at %d,%d",
                    entry.attempt.target, left.ends, left.pans,
                    left.pos[1], left.pos[2]))
            end
        end
    end
end

if arg and arg[0] and arg[0]:match("replay%.lua$") then
    main(arg)
end

return Replay
