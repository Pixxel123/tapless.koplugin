local logger = require("logger")

local DictionaryStore = {
    -- The most previous words whose followers are kept parsed at once.
    PAIR_ROWS = 256,
}
DictionaryStore.__index = DictionaryStore

-- The pair file's bucket for a previous word: its first two letters, or
-- a one-letter word twice ("a" is in bucket "aa"). An apostrophe is no
-- letter: "i'm" is in bucket "im".
local function pairKey(word)
    local letters = word:gsub("'", "")
    if #letters == 1 then
        return letters .. letters
    end
    return string.sub(letters, 1, 2)
end

function DictionaryStore:new(plugin_dir, registry, dictionary_index, time_api)
    return setmetatable({
        plugin_dir = plugin_dir or ".",
        registry = assert(registry),
        dictionary_index = assert(dictionary_index),
        time = assert(time_api),
        packages = {},
        bucket_cache = {},
        first_bucket_cache = {},
        popular_cache = {},
        word_presence_cache = {},
        pair_cache = {},
        prefetch_jobs = {},
    }, self)
end

local function closePackage(package)
    if package and package.file then
        package.file:close()
    end
    if package and package.popular_file then
        package.popular_file:close()
    end
    if package and package.pairs_file then
        package.pairs_file:close()
    end
end

function DictionaryStore:open(dictionary)
    dictionary = dictionary or "en"
    if self.packages[dictionary] ~= nil then
        return self.packages[dictionary]
    end

    local descriptor = self.registry:get(dictionary, self.plugin_dir)
    if not descriptor then
        self.packages[dictionary] = false
        logger.warn("swype mvp dictionary package missing", dictionary)
        return false
    end

    local data_file = io.open(descriptor.files.bucket_data, "rb")
    local index = self.dictionary_index:loadIndex(
        descriptor.files.bucket_index, 2)
    if not index or not data_file then
        if data_file then data_file:close() end
        self.packages[dictionary] = false
        logger.warn("swype mvp dictionary files unavailable", dictionary)
        return false
    end

    local popular_data_file = io.open(descriptor.files.popular_data, "rb")
    local popular_index = self.dictionary_index:loadIndex(
        descriptor.files.popular_index, 1)
    if not popular_index or not popular_data_file then
        if popular_data_file then popular_data_file:close() end
        popular_index = nil
        popular_data_file = nil
    end

    local pairs_file = descriptor.files.pairs_data
        and io.open(descriptor.files.pairs_data, "rb")
    local pairs_index = pairs_file and self.dictionary_index:loadIndex(
        descriptor.files.pairs_index, 2)
    if not pairs_index and pairs_file then
        pairs_file:close()
        pairs_file = nil
    end

    local package = {
        descriptor = descriptor,
        index = index,
        file = data_file,
        popular_index = popular_index,
        popular_file = popular_data_file,
        pairs_index = pairs_index,
        pairs_file = pairs_file,
    }
    self.packages[dictionary] = package
    logger.info("swype mvp bucket dictionary", descriptor.files.bucket_data,
        "language", descriptor.data_language)
    return package
end

function DictionaryStore:keepOnly(dictionary)
    for cached_dictionary, package in pairs(self.packages) do
        if cached_dictionary ~= dictionary then
            closePackage(package)
            self.packages[cached_dictionary] = nil
        end
    end
    for cached_dictionary in pairs(self.pair_cache) do
        if cached_dictionary ~= dictionary then
            self.pair_cache[cached_dictionary] = nil
        end
    end
    for cached_dictionary in pairs(self.bucket_cache) do
        if cached_dictionary ~= dictionary then
            self.bucket_cache[cached_dictionary] = nil
        end
    end
    for cached_dictionary in pairs(self.first_bucket_cache) do
        if cached_dictionary ~= dictionary then
            self.first_bucket_cache[cached_dictionary] = nil
        end
    end
    for cached_dictionary in pairs(self.popular_cache) do
        if cached_dictionary ~= dictionary then
            self.popular_cache[cached_dictionary] = nil
        end
    end
    for cached_dictionary in pairs(self.word_presence_cache) do
        if cached_dictionary ~= dictionary then
            self.word_presence_cache[cached_dictionary] = nil
        end
    end
    for cached_dictionary, jobs in pairs(self.prefetch_jobs) do
        if cached_dictionary ~= dictionary then
            for _, job in pairs(jobs) do
                job.cancelled = true
            end
            self.prefetch_jobs[cached_dictionary] = nil
        end
    end
end

function DictionaryStore:invalidate(dictionary)
    closePackage(self.packages[dictionary])
    self.packages[dictionary] = nil
    self.pair_cache[dictionary] = nil
    self.bucket_cache[dictionary] = nil
    self.first_bucket_cache[dictionary] = nil
    self.popular_cache[dictionary] = nil
    self.word_presence_cache[dictionary] = nil
    local jobs = self.prefetch_jobs[dictionary]
    for _, job in pairs(jobs or {}) do
        job.cancelled = true
    end
    self.prefetch_jobs[dictionary] = nil
end

-- Whether a word of the dictionary is spelled with these letters, whatever
-- its apostrophes, accents or capitals: "dont" has "don't".
function DictionaryStore:hasLetters(signature, dictionary)
    if type(signature) ~= "string" or not signature:match("^[a-z]+$") then
        return false
    end
    dictionary = dictionary or "en"
    self.word_presence_cache[dictionary] =
        self.word_presence_cache[dictionary] or {}
    local cache = self.word_presence_cache[dictionary]
    if cache[signature] ~= nil then
        return cache[signature]
    end
    local bucket = self:loadBucket(
        string.sub(signature, 1, 1), string.sub(signature, -1), dictionary)
    local found = false
    for _, entry in ipairs(bucket and bucket.entries or {}) do
        if entry.signature == signature then
            found = true
            break
        end
    end
    cache[signature] = found
    return found
end

-- The dictionary's own spelling of word, matched without regard to case
-- ("i'm" finds "I'm"), or nil when it is no word of the dictionary.
-- signature is the word's letters, as the word lists are keyed.
function DictionaryStore:findWord(signature, word, dictionary)
    if type(signature) ~= "string" or not signature:match("^[a-z]+$")
            or type(word) ~= "string" then
        return
    end
    local bucket = self:loadBucket(string.sub(signature, 1, 1),
        string.sub(signature, -1), dictionary or "en")
    local lowered = word:lower()
    for _, entry in ipairs(bucket and bucket.entries or {}) do
        if entry.signature == signature and entry.word:lower() == lowered then
            return entry.word
        end
    end
end

function DictionaryStore:discardPrefetch(controller)
    if not controller then
        return
    end
    local cache = self.bucket_cache[controller.dictionary] or {}
    local global_jobs = self.prefetch_jobs[controller.dictionary] or {}
    for key, job in pairs(controller.jobs) do
        if not job.completed then
            job.cancelled = true
        end
        if not job.used then
            cache[key] = nil
        end
        if global_jobs[key] == job then
            global_jobs[key] = nil
        end
    end
end

function DictionaryStore:isBucketLoaded(dictionary, key)
    local cache = self.bucket_cache[dictionary]
    return cache and cache[key] ~= nil
end

function DictionaryStore:advancePrefetch(job, max_entries, max_work_ms)
    if not job or job.cancelled or job.completed then
        return not job or job.completed
    end
    local work_start = self.time.now()
    local parsed = 0
    while not max_entries or parsed < max_entries do
        local line = job.next_line and job.next_line()
        if not line then
            job.completed = true
            self.bucket_cache[job.dictionary][job.key] = job.bucket
            break
        end
        self.dictionary_index:addBucketLine(job.bucket, line)
        parsed = parsed + 1
        if max_work_ms and parsed % 16 == 0
                and self.time.now() - work_start >= self.time.ms(max_work_ms) then
            break
        end
    end
    return job.completed
end

function DictionaryStore:startPrefetch(first, last, dictionary)
    dictionary = dictionary or "en"
    self.bucket_cache[dictionary] = self.bucket_cache[dictionary] or {}
    local cache = self.bucket_cache[dictionary]
    local key = (first or "") .. (last or "")
    if cache[key] then
        return
    end
    self.prefetch_jobs[dictionary] = self.prefetch_jobs[dictionary] or {}
    local jobs = self.prefetch_jobs[dictionary]
    if jobs[key] then
        return jobs[key]
    end
    local package = self:open(dictionary)
    if not package then
        return
    end

    local job = {
        dictionary = dictionary,
        key = key,
        bucket = self.dictionary_index:newBucket(),
    }
    local meta = package.index[key]
    if meta then
        package.file:seek("set", meta.offset)
        local data = package.file:read(meta.bytes) or ""
        job.next_line = data:gmatch("[^\n]+")
    else
        job.completed = true
        cache[key] = job.bucket
    end
    jobs[key] = job
    return job
end

function DictionaryStore:loadBucket(first, last, dictionary)
    dictionary = dictionary or "en"
    self.bucket_cache[dictionary] = self.bucket_cache[dictionary] or {}
    local cache = self.bucket_cache[dictionary]
    local key = (first or "") .. (last or "")
    local jobs = self.prefetch_jobs[dictionary]
    local prefetch_job = jobs and jobs[key]
    if cache[key] then
        if prefetch_job then
            prefetch_job.used = true
        end
        return cache[key]
    end
    if prefetch_job and not prefetch_job.cancelled then
        prefetch_job.used = true
        while not self:advancePrefetch(prefetch_job) do end
        return prefetch_job.bucket
    end
    local package = self:open(dictionary)
    if not package then
        return
    end

    local meta = package.index[key]
    local bucket = self.dictionary_index:readBucket(package.file, meta)
    cache[key] = bucket
    return bucket
end

-- Reads a word list a slice at a time, at most max_entries entries or
-- max_work_ms milliseconds per call, for callers that must not wait; true
-- once it is loaded. A list read this way, or one a swipe's prefetch read,
-- stays loaded when that prefetch is cancelled.
function DictionaryStore:loadBucketSlice(first, last, dictionary, max_entries,
        max_work_ms)
    dictionary = dictionary or "en"
    local key = first .. last
    local jobs = self.prefetch_jobs[dictionary]
    local job = jobs and jobs[key]
    if job and job.cancelled then
        jobs[key] = nil
        job = nil
    end
    if job then
        job.used = true
    end
    if self:isBucketLoaded(dictionary, key) then
        return true
    end
    job = job or self:startPrefetch(first, last, dictionary)
    if not job then
        return true
    end
    job.used = true
    return self:advancePrefetch(job, max_entries, max_work_ms)
end

function DictionaryStore:loadFirstBuckets(first, dictionary)
    dictionary = dictionary or "en"
    self.first_bucket_cache[dictionary] = self.first_bucket_cache[dictionary] or {}
    local cache = self.first_bucket_cache[dictionary]
    if cache[first] then
        return cache[first]
    end
    local entries = {}
    for code = string.byte("a"), string.byte("z") do
        local bucket = self:loadBucket(first, string.char(code), dictionary)
        for _, entry in ipairs(bucket and bucket.entries or {}) do
            table.insert(entries, entry)
        end
    end
    cache[first] = entries
    return entries
end

-- The words that tend to follow previous_word in the dictionary's
-- word-pair table, each with its bonus: { word = bonus }, or false when
-- there are none. A row is read from disk the first time it is asked for.
function DictionaryStore:pairRow(previous_word, dictionary)
    dictionary = dictionary or "en"
    local cache = self.pair_cache[dictionary]
    if not cache then
        cache = { size = 0, rows = {} }
        self.pair_cache[dictionary] = cache
    end
    local row = cache.rows[previous_word]
    if row ~= nil then
        return row
    end
    row = false
    local package = self:open(dictionary)
    local meta = package and package.pairs_index
        and type(previous_word) == "string"
        and previous_word:match("^[a-z][a-z']*$")
        and package.pairs_index[pairKey(previous_word)]
    if meta then
        package.pairs_file:seek("set", meta.offset)
        local data = "\n" .. (package.pairs_file:read(meta.bytes) or "")
        local line = data:match("\n" .. previous_word .. "\t([^\n]*)")
        if line then
            row = {}
            for word, bonus in line:gmatch("([^ :]+):(%d+)") do
                row[word] = tonumber(bonus)
            end
        end
    end
    if cache.size >= self.PAIR_ROWS then
        cache.size, cache.rows = 0, {}
    end
    cache.rows[previous_word] = row
    cache.size = cache.size + 1
    return row
end

-- The word-pair table's bonus for word following previous_word; 0 when
-- the dictionary has no table or no such pair.
function DictionaryStore:pairBonus(previous_word, word, dictionary)
    if not previous_word or not word then
        return 0
    end
    local row = self:pairRow(previous_word, dictionary)
    return row and row[word] or 0
end

function DictionaryStore:loadPopularWords(first, dictionary)
    dictionary = dictionary or "en"
    self.popular_cache[dictionary] = self.popular_cache[dictionary] or {}
    local cache = self.popular_cache[dictionary]
    if cache[first] then
        return cache[first]
    end

    local package = self:open(dictionary)
    if not package or not package.popular_index or not package.popular_file then
        return nil
    end
    local meta = package.popular_index[first]
    local bucket = self.dictionary_index:readBucket(package.popular_file, meta)
    cache[first] = bucket.entries
    return bucket.entries
end

return DictionaryStore
