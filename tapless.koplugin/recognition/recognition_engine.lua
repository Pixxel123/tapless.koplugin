local RecognitionEngine = {}
RecognitionEngine.__index = RecognitionEngine

-- Words that differ only in doubled letters ("we", "wwe", "wee") share a
-- gesture signature; at most this many of them take a place in the row.
RecognitionEngine.MAX_SAME_SHAPE = 2

-- A letter three times in a row ("tooo") marks a spelling nobody means.
local function tripled(word)
    return word:find("(%a)%1%1") ~= nil
end

local DYNAMIC_CANDIDATE_LIMIT = 40
local GEOMETRY_CANDIDATE_LIMIT = 12

function RecognitionEngine:new(dictionary_store, scoring, geometry_reranker,
        personal_dictionary, blocked_words)
    return setmetatable({
        dictionary_store = assert(dictionary_store),
        scoring = assert(scoring),
        geometry_reranker = geometry_reranker,
        personal_dictionary = personal_dictionary,
        blocked_words = blocked_words,
    }, self)
end

function RecognitionEngine:pickCandidates(options)
    local signature = options.signature
    local limit = options.limit or 3
    local dictionary = options.dictionary or "en"
    local trace_info = options.trace_info
    local key_centers = options.key_centers or {}
    local package = self.dictionary_store:open(dictionary)
    if not package then
        return {}
    end
    local data_lang = package.descriptor.data_language or dictionary
    local trace_chars, next_positions = self.scoring:buildNextPositions(signature)
    local near = self.scoring:buildNearPositions(trace_chars, key_centers,
        trace_info and trace_info.observations)
    local first = string.sub(signature, 1, 1)
    local last = string.sub(signature, -1)
    local max_spatial = math.max(6, #signature)
    local shortlist, seen = {}, {}

    local blocked_words = self.blocked_words
    local function scan(entries, allow_endpoint_mismatch, allow_start_mismatch)
        for _, entry in ipairs(entries or {}) do
            if (not entry.lang or entry.lang == dictionary
                    or entry.lang == data_lang)
                    and not (blocked_words
                        and blocked_words:contains(dictionary, entry.word)) then
                local context_bonus = options.context_bonus
                    and options.context_bonus(
                        trace_info and trace_info.previous_word, entry.word) or 0
                local uses = options.word_uses
                    and options.word_uses(entry.word) or 0
                local spatial_score, ranked_score, used_near =
                    self.scoring:scoreEntry(
                    signature,
                    entry,
                    trace_chars,
                    next_positions,
                    trace_info,
                    key_centers,
                    allow_endpoint_mismatch,
                    context_bonus,
                    allow_start_mismatch,
                    near,
                    uses)
                if spatial_score <= max_spatial then
                    self.scoring:addCandidate(shortlist, seen, entry,
                        spatial_score, ranked_score,
                        math.max(limit, DYNAMIC_CANDIDATE_LIMIT), {
                            allow_endpoint_mismatch = allow_endpoint_mismatch,
                            allow_start_mismatch = allow_start_mismatch,
                            allow_near = used_near,
                            context_bonus = context_bonus,
                            uses = uses,
                            entry = entry,
                        })
                end
            end
        end
    end

    local personal_bucket = self.personal_dictionary
        and self.personal_dictionary:getBucket(first, last, dictionary,
            options.normalization_profile)
    scan(personal_bucket and personal_bucket.entries)

    local bucket = self.dictionary_store:loadBucket(first, last, dictionary)
    for length = 2, math.min(14, #signature) do
        scan(bucket and bucket.by_gesture_length[length])
    end

    if #signature >= 3 and trace_info and trace_info.endpoint_pos
            and options.endpoint_letters then
        local endpoint_letters = options.endpoint_letters(last)
        if #endpoint_letters > 1 then
            for index = 2, #endpoint_letters do
                local endpoint_last = endpoint_letters[index]
                local endpoint_bucket = self.dictionary_store:loadBucket(
                    first, endpoint_last, dictionary)
                local personal_endpoint_bucket = self.personal_dictionary
                    and self.personal_dictionary:getBucket(
                        first, endpoint_last, dictionary,
                        options.normalization_profile)
                scan(personal_endpoint_bucket
                    and personal_endpoint_bucket.entries, true)
                for length = 2, math.min(14, #signature) do
                    scan(endpoint_bucket
                        and endpoint_bucket.by_gesture_length[length], true)
                end
            end
        end
    end

    -- The swipe may have started on a key next to the intended one.
    if #signature >= 3 and trace_info and options.start_letters then
        local start_letters = options.start_letters(first)
        for index = 2, #start_letters do
            local start_first = start_letters[index]
            local personal_start_bucket = self.personal_dictionary
                and self.personal_dictionary:getBucket(
                    start_first, last, dictionary,
                    options.normalization_profile)
            scan(personal_start_bucket and personal_start_bucket.entries,
                false, true)
            local start_bucket = self.dictionary_store:loadBucket(
                start_first, last, dictionary)
            for length = 2, math.min(14, #signature) do
                scan(start_bucket and start_bucket.by_gesture_length[length],
                    false, true)
            end
        end
    end

    if #shortlist == 0 then
        local popular_entries = self.dictionary_store:loadPopularWords(
            first, dictionary)
        if popular_entries then
            scan(popular_entries)
        else
            scan(self.dictionary_store:loadFirstBuckets(first, dictionary))
        end
    end
    local results, final_seen = {}, {}
    for _, candidate in ipairs(shortlist) do
        local metadata = candidate.metadata
        local entry = metadata and metadata.entry
        if entry then
            local spatial_score, ranked_score = self.scoring:scoreEntryDynamic(
                signature,
                entry,
                trace_chars,
                trace_info,
                key_centers,
                metadata.allow_endpoint_mismatch,
                metadata.context_bonus,
                metadata.allow_start_mismatch,
                metadata.allow_near and near or nil,
                metadata.uses)
            if spatial_score <= max_spatial then
                self.scoring:addCandidate(results, final_seen, entry,
                    spatial_score, ranked_score,
                    math.max(limit, GEOMETRY_CANDIDATE_LIMIT))
            end
        end
    end
    if #results > 0 then
        if self.geometry_reranker then
            results = self.geometry_reranker:rerank(
                results, trace_info, key_centers, #results)
        end
        return self:fillRow(results, limit)
    end

    local fallback = {}
    for index = 1, math.min(limit, #shortlist) do
        local candidate = shortlist[index]
        fallback[index] = {
            word = candidate.word,
            signature = candidate.signature,
            spatial_score = candidate.spatial_score,
            ranked_score = candidate.ranked_score,
        }
    end
    return fallback
end

-- Words that complete a word being tapped out, best first. options:
-- prefix, the letters typed so far as a signature (normalised, lowercase);
-- typed, the word as typed, lowercased, left out; dictionary; limit;
-- normalization_profile; context_bonus(previous_word, word) and
-- previous_word; word_uses(word); and full, which also looks through
-- every word starting with the prefix's letter, not only the most common,
-- once the prefix has FULL_COMPLETION_PREFIX letters and too few matched
-- (only_loaded: only the word lists already read from disk).
-- Each result is { word, signature, ranked_score, personal }: frequency,
-- plus what the word earns after the previous word and from its uses.
RecognitionEngine.FULL_COMPLETION_PREFIX = 3

function RecognitionEngine:completeWord(options)
    local prefix = options.prefix or ""
    local limit = options.limit or 4
    local dictionary = options.dictionary or "en"
    if #prefix == 0 then
        return {}
    end
    local package = self.dictionary_store:open(dictionary)
    if not package then
        return {}
    end
    local data_lang = package.descriptor.data_language or dictionary
    local typed = options.typed
    local first = string.sub(prefix, 1, 1)
    local results, seen = {}, {}
    local function consider(entry, personal)
        local word = entry.word
        local signature = entry.signature or ""
        -- Only a word with just the typed letters can be the word typed;
        -- only such a word needs lowering ("I'm" for "i'm").
        if not word or string.sub(signature, 1, #prefix) ~= prefix
                or (#signature == #prefix and word:lower() == typed)
                or seen[word] or tripled(word)
                or (entry.lang and entry.lang ~= dictionary
                    and entry.lang ~= data_lang)
                or (self.blocked_words
                    and self.blocked_words:contains(dictionary, word)) then
            return
        end
        seen[word] = true
        local freq = entry.freq or 0
        local uses = options.word_uses and options.word_uses(word) or 0
        local bonus = options.context_bonus
            and options.context_bonus(options.previous_word, word) or 0
        results[#results + 1] = {
            word = word,
            signature = entry.signature,
            ranked_score = freq + bonus
                + self.scoring:usageBonus(freq, uses),
            personal = personal == true,
        }
    end
    if self.personal_dictionary then
        for code = string.byte("a"), string.byte("z") do
            local bucket = self.personal_dictionary:getBucket(first,
                string.char(code), dictionary, options.normalization_profile)
            for _, entry in ipairs(bucket and bucket.entries or {}) do
                consider(entry, true)
            end
        end
    end
    for _, entry in ipairs(self.dictionary_store:loadPopularWords(
            first, dictionary) or {}) do
        consider(entry)
    end
    if options.full and #prefix >= self.FULL_COMPLETION_PREFIX
            and #results < limit then
        local store = self.dictionary_store
        for code = string.byte("a"), string.byte("z") do
            local last = string.char(code)
            -- only_loaded: never wait for the disk; what is not loaded yet
            -- is left out.
            if not options.only_loaded
                    or store:isBucketLoaded(dictionary, first .. last) then
                local bucket = store:loadBucket(first, last, dictionary)
                for _, entry in ipairs(bucket and bucket.entries or {}) do
                    consider(entry)
                end
            end
        end
    end
    table.sort(results, function(left, right)
        if left.ranked_score ~= right.ranked_score then
            return left.ranked_score > right.ranked_score
        end
        return left.word < right.word
    end)
    for index = #results, limit + 1, -1 do
        results[index] = nil
    end
    return results
end

-- The suggestion row: candidates in rank order, leaving out spellings
-- that only repeat letters of a word already shown. If that leaves out
-- everything, the best candidates are shown as they are.
function RecognitionEngine:fillRow(candidates, limit)
    local row, shapes = {}, {}
    for _, candidate in ipairs(candidates) do
        if #row >= limit then
            break
        end
        local word = (candidate.word or ""):lower()
        local shape = candidate.gesture_signature or word
        local count = shapes[shape] or 0
        if not tripled(word) and count < self.MAX_SAME_SHAPE then
            shapes[shape] = count + 1
            row[#row + 1] = candidate
        end
    end
    if #row == 0 then
        for index = 1, math.min(limit, #candidates) do
            row[index] = candidates[index]
        end
    end
    return row
end

return RecognitionEngine
