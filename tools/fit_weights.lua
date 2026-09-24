-- Fits the weights that turn Tapless's per-word evidence into a ranking,
-- from recorded swipe test sessions.
--
-- luajit tools/fit_weights.lua [--plugin DIR] SESSION.jsonl...
--
-- A candidate's ranked score is a weighted sum of its features (spatial
-- score, word frequency, rarity, repeated-letter credit, geometry score).
-- Reading exp(-score) as how likely the swipe meant that word gives a
-- conditional logit model: the chance of the intended word is its softmax
-- share among the swipe's candidates. The weights that make the intended
-- words most likely are found by Newton's method. Each session is held out
-- in turn, so the reported accuracy is on swipes the fit did not see.
local tools_dir = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")
    or "."
package.path = tools_dir .. "/?.lua;" .. package.path
local Replay = dofile(tools_dir .. "/replay.lua")

local FitWeights = {
    FEATURES = { "spatial", "frequency", "rarity", "repeat", "geometry",
        "borrowed" },
    -- Ridge penalty: keeps weights finite when a feature separates the
    -- few swipes it appears in.
    RIDGE = 0.01,
    ITERATIONS = 50,
}

-- The current constants in the same units: ranked_score / 1000 is
--   3 * spatial - freq / 1000 + 12 * rare - 4.5 * repeat + 1.8 * geometry
-- A borrowed letter is not its own feature today: it just adds
-- NEAR_KEY_COST to the spatial score, so its starting weight is 0.
function FitWeights.currentWeights(scoring, reranker)
    return {
        scoring.SCORE_UNIT / 1000,
        1,
        scoring.RARE_SHORT_COST * scoring.SCORE_UNIT / 1000,
        scoring.REPEAT_BONUS / 1000,
        reranker.RANK_WEIGHT / 1000,
        0,
    }
end

-- How many of a candidate's interior letters (not the first or last,
-- which are start/endpoint mismatches rather than borrowings) differ
-- from the trace letter they were matched to.
function FitWeights.borrowedLetters(candidate, trace_chars,
        matched_positions)
    local count = 0
    for p = 2, #candidate - 1 do
        local matched = matched_positions[p]
        if matched and candidate:sub(p, p) ~= trace_chars[matched] then
            count = count + 1
        end
    end
    return count
end

-- Replays one attempt and returns its candidates' features, with the
-- intended word's index, or nil when the intended word was not a candidate.
function FitWeights.candidateFeatures(plugin, attempt)
    local engine = plugin.engine
    local scoring = engine.scoring
    local captured, options
    local original_pick = engine.pickCandidates
    local original_add = scoring.addCandidate
    engine.pickCandidates = function(self, opts)
        options = opts
        return original_pick(self, opts)
    end
    scoring.addCandidate = function(self, results, seen, entry, spatial,
            ranked, limit, metadata)
        if metadata then
            captured = results
        end
        return original_add(self, results, seen, entry, spatial, ranked,
            limit, metadata)
    end
    local ok, result = pcall(Replay.run, plugin, attempt)
    engine.pickCandidates = nil
    scoring.addCandidate = nil
    if not ok then
        error(result)
    end
    if result.short or not captured or not options then
        return nil
    end

    local signature = options.signature
    local trace_info = options.trace_info
    local key_centers = options.key_centers
    local trace_chars = scoring:buildNextPositions(signature)
    local near = scoring:buildNearPositions(trace_chars, key_centers,
        trace_info.observations)
    local max_spatial = math.max(6, #signature)
    local target = attempt.target:lower()
    local rows, target_index = {}, nil
    local geometry_total, geometry_count = 0, 0
    for _, candidate in ipairs(captured) do
        local metadata = candidate.metadata
        local entry = metadata.entry
        local spatial, ranked = scoring:scoreEntryDynamic(signature, entry,
            trace_chars, trace_info, key_centers,
            metadata.allow_endpoint_mismatch, 0,
            metadata.allow_start_mismatch,
            metadata.allow_near and near or nil)
        if spatial <= max_spatial then
            local freq = entry.freq or 0
            local rare = #(entry.signature or entry.word)
                    <= scoring.RARE_SHORT_LENGTH
                and freq < scoring.RARE_SHORT_FREQ and 1 or 0
            -- What finishEntryScore took off for repeated letters.
            local repeat_credit = (spatial * scoring.SCORE_UNIT - freq
                + rare * scoring.RARE_SHORT_COST * scoring.SCORE_UNIT
                - ranked) / scoring.REPEAT_BONUS
            local candidate_signature = entry.gesture_signature
                or entry.signature
            local geometry = plugin.engine.geometry_reranker:score(
                trace_info.points, candidate_signature, key_centers)
            if geometry then
                geometry_total = geometry_total + geometry
                geometry_count = geometry_count + 1
            end
            -- The third return is matched_positions, used only here to
            -- count letters borrowed from a neighbouring key.
            local _, _, matched_positions = scoring:dynamicMatchScore(
                candidate_signature, trace_chars,
                metadata.allow_endpoint_mismatch, trace_info.letter_points,
                trace_info.endpoint_pos, key_centers,
                trace_info.observations, metadata.allow_start_mismatch,
                metadata.allow_near and near or nil)
            local borrowed = FitWeights.borrowedLetters(candidate_signature,
                trace_chars, matched_positions)
            rows[#rows + 1] = {
                word = entry.word,
                features = { spatial, -freq / 1000, rare, -repeat_credit,
                    geometry or false, borrowed },
            }
            if entry.word:lower() == target then
                target_index = #rows
            end
        end
    end
    -- As the reranker does: a word with no geometry score gets the mean.
    local neutral = geometry_count > 0 and geometry_total / geometry_count
        or 0
    for _, row in ipairs(rows) do
        row.features[5] = row.features[5] or neutral
    end
    if not target_index or #rows < 2 then
        return nil
    end
    return { rows = rows, target = target_index, word = target }
end

local function scores(swipe, weights)
    local out = {}
    for index, row in ipairs(swipe.rows) do
        local total = 0
        for k = 1, #weights do
            total = total + weights[k] * row.features[k]
        end
        out[index] = total
    end
    return out
end

-- Softmax shares of exp(-score), computed stably.
local function shares(values)
    local low = math.huge
    for _, value in ipairs(values) do
        low = math.min(low, value)
    end
    local total, out = 0, {}
    for index, value in ipairs(values) do
        out[index] = math.exp(low - value)
        total = total + out[index]
    end
    for index = 1, #out do
        out[index] = out[index] / total
    end
    return out
end

-- Negative log-likelihood of the intended words, plus the ridge penalty.
function FitWeights.loss(swipes, weights, ridge)
    local total = 0
    for _, swipe in ipairs(swipes) do
        local p = shares(scores(swipe, weights))
        total = total - math.log(math.max(p[swipe.target], 1e-300))
    end
    for k = 1, #weights do
        total = total + (ridge or 0) * weights[k] * weights[k]
    end
    return total
end

local function solve(matrix, vector)
    local n = #vector
    local a = {}
    for i = 1, n do
        a[i] = {}
        for j = 1, n do
            a[i][j] = matrix[i][j]
        end
        a[i][n + 1] = vector[i]
    end
    for col = 1, n do
        local pivot = col
        for row = col + 1, n do
            if math.abs(a[row][col]) > math.abs(a[pivot][col]) then
                pivot = row
            end
        end
        a[col], a[pivot] = a[pivot], a[col]
        for row = col + 1, n do
            local factor = a[row][col] / a[col][col]
            for j = col, n + 1 do
                a[row][j] = a[row][j] - factor * a[col][j]
            end
        end
    end
    local x = {}
    for i = n, 1, -1 do
        local sum = a[i][n + 1]
        for j = i + 1, n do
            sum = sum - a[i][j] * x[j]
        end
        x[i] = sum / a[i][i]
    end
    return x
end

-- Gradient and Hessian of the penalized negative log-likelihood, at
-- weights. Shared by fit (which walks downhill with it) and
-- standardErrors (which only needs the Hessian at the fitted point).
local function gradientAndHessian(swipes, weights, ridge)
    local n = #weights
    local gradient, hessian = {}, {}
    for i = 1, n do
        gradient[i] = 2 * ridge * weights[i]
        hessian[i] = {}
        for j = 1, n do
            hessian[i][j] = i == j and 2 * ridge or 0
        end
    end
    for _, swipe in ipairs(swipes) do
        local p = shares(scores(swipe, weights))
        local mean = {}
        for k = 1, n do
            mean[k] = 0
            for c, row in ipairs(swipe.rows) do
                mean[k] = mean[k] + p[c] * row.features[k]
            end
            gradient[k] = gradient[k]
                + swipe.rows[swipe.target].features[k] - mean[k]
        end
        for c, row in ipairs(swipe.rows) do
            for i = 1, n do
                local di = row.features[i] - mean[i]
                for j = 1, n do
                    hessian[i][j] = hessian[i][j]
                        + p[c] * di * (row.features[j] - mean[j])
                end
            end
        end
    end
    return gradient, hessian
end

-- Newton's method on the (convex) penalized negative log-likelihood.
function FitWeights.fit(swipes, start, ridge, iterations)
    ridge = ridge or FitWeights.RIDGE
    local n = #start
    local weights = { unpack(start) }
    local current = FitWeights.loss(swipes, weights, ridge)
    for _ = 1, iterations or FitWeights.ITERATIONS do
        local gradient, hessian = gradientAndHessian(swipes, weights, ridge)
        local step = solve(hessian, gradient)
        local scale, improved = 1, false
        for _ = 1, 20 do
            local trial = {}
            for k = 1, n do
                trial[k] = weights[k] - scale * step[k]
            end
            local value = FitWeights.loss(swipes, trial, ridge)
            if value < current then
                weights, current, improved = trial, value, true
                break
            end
            scale = scale / 2
        end
        if not improved then
            break
        end
    end
    return weights
end

-- Standard errors of fitted weights: the square roots of the diagonal
-- of the penalized Hessian's inverse, found one column at a time with
-- the same solver fit uses.
function FitWeights.standardErrors(swipes, weights, ridge)
    ridge = ridge or FitWeights.RIDGE
    local n = #weights
    local _, hessian = gradientAndHessian(swipes, weights, ridge)
    local errors = {}
    for k = 1, n do
        local unit = {}
        for i = 1, n do
            unit[i] = i == k and 1 or 0
        end
        local column = solve(hessian, unit)
        errors[k] = math.sqrt(column[k])
    end
    return errors
end

-- How many swipes put the intended word first. Ties go to the earlier
-- candidate, as the engine's stable insertion does.
function FitWeights.topOne(swipes, weights)
    local hits = 0
    for _, swipe in ipairs(swipes) do
        local s = scores(swipe, weights)
        local best = 1
        for index = 2, #s do
            if s[index] < s[best] then
                best = index
            end
        end
        if best == swipe.target then
            hits = hits + 1
        end
    end
    return hits
end

-- The fitted weights as the plugin's constants, frequency held at 1.
function FitWeights.constants(weights)
    local per_freq = 1000 / weights[2]
    local score_unit = weights[1] * per_freq
    return {
        SCORE_UNIT = score_unit,
        RARE_SHORT_COST = weights[3] * per_freq / score_unit,
        REPEAT_BONUS = weights[4] * per_freq,
        RANK_WEIGHT = weights[5] * per_freq,
        NEAR_RANK_COST = weights[6] and weights[6] * per_freq or 0,
    }
end

-- Copies swipes with feature 6 dropped, to fit and score without it.
local function withoutLast(swipes)
    local out = {}
    for index, swipe in ipairs(swipes) do
        local rows = {}
        for row_index, row in ipairs(swipe.rows) do
            rows[row_index] = { word = row.word,
                features = { unpack(row.features, 1, 5) } }
        end
        out[index] = { rows = rows, target = swipe.target, word = swipe.word }
    end
    return out
end

local function main(args)
    local plugin_dir = tools_dir .. "/../tapless.koplugin"
    local paths = {}
    local index = 1
    while index <= #args do
        if args[index] == "--plugin" then
            index = index + 1
            plugin_dir = args[index]
        else
            paths[#paths + 1] = args[index]
        end
        index = index + 1
    end
    if #paths < 2 then
        io.stderr:write("usage: luajit tools/fit_weights.lua [--plugin DIR]"
            .. " SESSION.jsonl SESSION.jsonl...\n"
            .. "(at least two sessions: each is held out in turn)\n")
        os.exit(2)
    end
    local json = require("dkjson")
    local plugin = Replay.loadPlugin(plugin_dir)
    local start = FitWeights.currentWeights(plugin.engine.scoring,
        plugin.engine.geometry_reranker)

    local sessions, all, skipped, total = {}, {}, 0, 0
    for session_index, path in ipairs(paths) do
        sessions[session_index] = {}
        for line in io.lines(path) do
            local record = json.decode(line)
            if record and record.type == "attempt" and record.target then
                total = total + 1
                local swipe = FitWeights.candidateFeatures(plugin, record)
                if swipe then
                    table.insert(sessions[session_index], swipe)
                    table.insert(all, swipe)
                else
                    skipped = skipped + 1
                end
            end
        end
    end
    print(string.format("%d swipes, %d usable (%d without the intended "
        .. "word among the candidates)", total, #all, skipped))

    local short_start = { unpack(start, 1, 5) }
    print("\nHeld-out session     n  current  -borrow  fitted")
    local held_current, held_no_borrow, held_fitted, held_n = 0, 0, 0, 0
    for held, test in ipairs(sessions) do
        local train = {}
        for other, swipes in ipairs(sessions) do
            if other ~= held then
                for _, swipe in ipairs(swipes) do
                    train[#train + 1] = swipe
                end
            end
        end
        local weights = FitWeights.fit(train, start)
        local no_borrow_weights = FitWeights.fit(withoutLast(train),
            short_start)
        local current = FitWeights.topOne(test, start)
        local no_borrow = FitWeights.topOne(withoutLast(test),
            no_borrow_weights)
        local fitted = FitWeights.topOne(test, weights)
        held_current = held_current + current
        held_no_borrow = held_no_borrow + no_borrow
        held_fitted = held_fitted + fitted
        held_n = held_n + #test
        print(string.format("  %-16s %4d  %7d  %7d  %6d",
            paths[held]:match("[^/]*$"):sub(1, 16), #test, current,
            no_borrow, fitted))
    end
    print(string.format("  %-16s %4d  %7d  %7d  %6d", "all held out",
        held_n, held_current, held_no_borrow, held_fitted))

    local weights = FitWeights.fit(all, start)
    local se = FitWeights.standardErrors(all, weights)
    print("\nWeights fitted on every session (frequency held at 1;"
        .. " ± is 1.96 SE, ignoring the frequency weight's own"
        .. " uncertainty):")
    local constants = FitWeights.constants(weights)
    -- Each constant's SE is its weight's SE run through the same scale
    -- factor as the constant itself; the frequency weight's own SE is
    -- not propagated.
    local per_freq = 1000 / weights[2]
    local score_unit = weights[1] * per_freq
    local se_constants = {
        SCORE_UNIT = se[1] * per_freq,
        RARE_SHORT_COST = se[3] * per_freq / score_unit,
        REPEAT_BONUS = se[4] * per_freq,
        RANK_WEIGHT = se[5] * per_freq,
        NEAR_RANK_COST = se[6] and se[6] * per_freq or 0,
    }
    print(string.format("  SCORE_UNIT       %8.0f ± %-6.0f (now %d)",
        constants.SCORE_UNIT, 1.96 * se_constants.SCORE_UNIT,
        plugin.engine.scoring.SCORE_UNIT))
    print(string.format("  RARE_SHORT_COST  %8.2f ± %-6.2f (now %d)",
        constants.RARE_SHORT_COST, 1.96 * se_constants.RARE_SHORT_COST,
        plugin.engine.scoring.RARE_SHORT_COST))
    print(string.format("  REPEAT_BONUS     %8.0f ± %-6.0f (now %d)",
        constants.REPEAT_BONUS, 1.96 * se_constants.REPEAT_BONUS,
        plugin.engine.scoring.REPEAT_BONUS))
    print(string.format("  RANK_WEIGHT      %8.0f ± %-6.0f (now %d)",
        constants.RANK_WEIGHT, 1.96 * se_constants.RANK_WEIGHT,
        plugin.engine.geometry_reranker.RANK_WEIGHT))
    print(string.format("  NEAR_RANK_COST   %8.0f ± %-6.0f (now %d)",
        constants.NEAR_RANK_COST, 1.96 * se_constants.NEAR_RANK_COST, 0))
    print(string.format("  negative log-likelihood %.1f (current weights"
        .. " %.1f)", FitWeights.loss(all, weights, 0),
        FitWeights.loss(all, start, 0)))

    local borrowed_swipes = 0
    for _, swipe in ipairs(all) do
        for _, row in ipairs(swipe.rows) do
            if row.features[6] > 0 then
                borrowed_swipes = borrowed_swipes + 1
                break
            end
        end
    end
    print(string.format("\n%d usable swipes have a candidate that borrowed "
        .. "a letter from a neighbouring key", borrowed_swipes))
end

if arg and arg[0] and arg[0]:match("fit_weights%.lua$") then
    main(arg)
end

return FitWeights
