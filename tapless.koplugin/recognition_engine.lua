local RecognitionEngine = {}
RecognitionEngine.__index = RecognitionEngine

function RecognitionEngine:new(dictionary_store, scoring)
    return setmetatable({
        dictionary_store = assert(dictionary_store),
        scoring = assert(scoring),
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
    local results, seen = {}, {}

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
                    self.scoring:addCandidate(results, seen, entry,
                        spatial_score, ranked_score, limit)
                end
            end
        end
    end

    local bucket = self.dictionary_store:loadBucket(first, last, dictionary)
    for length = 2, math.min(14, #signature) do
        scan(bucket and bucket.by_length[length])
    end

    if #signature >= 3 and trace_info and trace_info.endpoint_pos
            and options.endpoint_letters then
        local endpoint_letters = options.endpoint_letters(last)
        if #endpoint_letters > 1 then
            for index = 2, #endpoint_letters do
                local endpoint_last = endpoint_letters[index]
                local endpoint_bucket = self.dictionary_store:loadBucket(
                    first, endpoint_last, dictionary)
                for length = 2, math.min(14, #signature) do
                    scan(endpoint_bucket and endpoint_bucket.by_length[length], true)
                end
            end
        end
    end

    if #results == 0 then
        local popular_entries = self.dictionary_store:loadPopularWords(
            first, dictionary)
        if popular_entries then
            scan(popular_entries)
        else
            scan(self.dictionary_store:loadFirstBuckets(first, dictionary))
        end
    end
    return results
end

return RecognitionEngine
