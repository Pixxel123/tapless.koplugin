local RecognitionEngine = {}
RecognitionEngine.__index = RecognitionEngine

local DYNAMIC_CANDIDATE_LIMIT = 40
local GEOMETRY_CANDIDATE_LIMIT = 12

function RecognitionEngine:new(dictionary_store, scoring, geometry_reranker,
        personal_dictionary)
    return setmetatable({
        dictionary_store = assert(dictionary_store),
        scoring = assert(scoring),
        geometry_reranker = geometry_reranker,
        personal_dictionary = personal_dictionary,
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
    local first = string.sub(signature, 1, 1)
    local last = string.sub(signature, -1)
    local max_spatial = math.max(6, #signature)
    local shortlist, seen = {}, {}

    local function scan(entries, allow_endpoint_mismatch)
        for _, entry in ipairs(entries or {}) do
            if not entry.lang or entry.lang == dictionary or entry.lang == data_lang then
                local context_bonus = options.context_bonus
                    and options.context_bonus(
                        trace_info and trace_info.previous_word, entry.word) or 0
                local spatial_score, ranked_score = self.scoring:scoreEntry(
                    signature,
                    entry,
                    trace_chars,
                    next_positions,
                    trace_info,
                    key_centers,
                    allow_endpoint_mismatch,
                    context_bonus)
                if spatial_score <= max_spatial then
                    self.scoring:addCandidate(shortlist, seen, entry,
                        spatial_score, ranked_score,
                        math.max(limit, DYNAMIC_CANDIDATE_LIMIT), {
                            allow_endpoint_mismatch = allow_endpoint_mismatch,
                            context_bonus = context_bonus,
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
                metadata.context_bonus)
            if spatial_score <= max_spatial then
                self.scoring:addCandidate(results, final_seen, entry,
                    spatial_score, ranked_score,
                    math.max(limit, GEOMETRY_CANDIDATE_LIMIT))
            end
        end
    end
    if #results > 0 then
        if self.geometry_reranker then
            return self.geometry_reranker:rerank(
                results, trace_info, key_centers, limit)
        end
        while #results > limit do
            table.remove(results)
        end
        return results
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

return RecognitionEngine
