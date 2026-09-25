local T = require("helper")
local it = T.it

package.preload["logger"] = package.preload["logger"] or function()
    local function noop() end
    return { info = noop, warn = noop, dbg = noop, err = noop }
end

local ContextModel = T.load("context_model")
local DictionaryStore = T.load("dictionary_store")
local DictionaryIndex = T.load("dictionary_index")
local BUILD = T.plugin_dir .. "/../tools/build_word_pairs.py"

local function newSettings(values)
    local settings = { values = values or {} }
    function settings:readSetting(key, default)
        if self.values[key] == nil then return default end
        return self.values[key]
    end
    function settings:saveSetting(key, value)
        self.values[key] = value
    end
    return settings
end

local function write(path, text)
    local file = assert(io.open(path, "w"))
    file:write(text)
    file:close()
end

local function read(path)
    local file = io.open(path)
    if not file then return nil end
    local text = file:read("*a")
    file:close()
    return text
end

-- A dictionary folder holding the words the corpus below uses.
local function newDictionary()
    local dir = os.tmpname()
    os.remove(dir)
    os.execute('mkdir -p "' .. dir .. '"')
    local lines = {}
    for _, word in ipairs({ "a", "cat", "dog", "ran", "sat", "the" }) do
        lines[#lines + 1] = word .. "\t" .. word .. "\t5000\ten\n"
    end
    local data = table.concat(lines)
    write(dir .. "/words.buckets.tsv", data)
    write(dir .. "/words.buckets.idx", "# key\toffset\tbytes\trows\n"
        .. "aa\t0\t" .. #data .. "\t" .. #lines .. "\n")
    write(dir .. "/manifest.tsv", "id\ten\n")
    -- "cat, dog": no pair, the comma ends what the keyboard sees.
    write(dir .. "/corpus.txt", "the cat sat\nthe cat sat\nthe dog ran\n"
        .. "a dog ran\ncat, dog\n")
    return dir
end

local function build(dir, options)
    local ok = os.execute("python3 " .. BUILD .. " --dictionary " .. dir
        .. " --min-count 1 " .. (options or "") .. " " .. dir
        .. "/corpus.txt 2>/dev/null")
    T.truthy(ok == 0 or ok == true, "build_word_pairs.py ran")
end

local function newStore(dir, with_pairs)
    local files = {
        bucket_data = dir .. "/words.buckets.tsv",
        bucket_index = dir .. "/words.buckets.idx",
        popular_data = dir .. "/words.popular.tsv",
        popular_index = dir .. "/words.popular.idx",
    }
    if with_pairs ~= false then
        files.pairs_data = dir .. "/words.pairs.tsv"
        files.pairs_index = dir .. "/words.pairs.idx"
    end
    local registry = {
        get = function(_, id)
            return { id = id, data_language = id, files = files }
        end,
    }
    return DictionaryStore:new(dir, registry, DictionaryIndex,
        { now = function() return 0 end, ms = function(n) return n end })
end

local function remove(dir)
    os.execute('rm -rf "' .. dir .. '"')
end

it("adds the table's bonus to a learned pair, capped", function()
    local model = ContextModel:new(newSettings(), "pairs")
    T.eq(model:bonus("the", "cat"), 0)
    T.eq(model:bonus("the", "cat", 700), 700)
    T.eq(model:bonus(nil, "cat", 700), 700, "no previous word learned")
    model:learn("the", "cat")
    T.eq(model:bonus("the", "cat"), 600)
    T.eq(model:bonus("the", "cat", 500), 1100)
    T.eq(model:bonus("the", "cat", 5000), model.MAX_BONUS)
end)

it("drops the previous word followed least when it holds too many",
        function()
    local model = ContextModel:new(newSettings(), "pairs")
    model.MAX_PREVIOUS = 2
    model:learn("a", "x")
    model:learn("a", "x")
    model:learn("b", "y")
    model:learn("c", "z")
    local counts = model:getCounts()
    T.eq(counts.b, nil, "the least followed goes")
    T.eq(counts.a.x, 2)
    T.eq(counts.c.z, 1, "the new one stays")
end)

it("counts the previous words already saved", function()
    local model = ContextModel:new(newSettings({
        pairs = { a = { x = 1 }, b = { y = 3 } },
    }), "pairs")
    model.MAX_PREVIOUS = 2
    model:learn("c", "z")
    local counts = model:getCounts()
    T.eq(counts.a, nil)
    T.eq(counts.b.y, 3)
    T.eq(counts.c.z, 1)
end)

it("builds a word-pair table the store reads back", function()
    local dir = newDictionary()
    build(dir, "--min-bonus 0")
    local store = newStore(dir)
    -- 14 words; "the" leads 3 pairs, 2 of them "the cat"; "cat" is 3 of
    -- the 14: 1000 * log10((2/3) / (3/14)).
    T.eq(store:pairBonus("the", "cat", "en"), 493)
    T.eq(store:pairBonus("the", "dog", "en"), 192)
    T.eq(store:pairBonus("a", "dog", "en"), 669, "a one-letter word")
    T.eq(store:pairBonus("cat", "dog", "en"), 0, "split by a comma")
    T.eq(store:pairBonus("the", "ran", "en"), 0, "never seen together")
    T.eq(store:pairBonus("zebra", "cat", "en"), 0, "no such row")
    T.eq(store:pairBonus("can't", "cat", "en"), 0)
    T.eq(store:pairBonus(nil, "cat", "en"), 0)
    local manifest = read(dir .. "/manifest.tsv")
    T.truthy(manifest:find("\nsha256_pairs_data\t%x+\n"), manifest)
    T.truthy(manifest:find("\npairs_index\twords.pairs.idx\n"), manifest)
    remove(dir)
end)

it("leaves out weak pairs and the sentences it is told to", function()
    local dir = newDictionary()
    build(dir)
    T.eq(newStore(dir):pairBonus("the", "dog", "en"), 0,
        "below the smallest bonus kept")
    write(dir .. "/prompts.txt", "The cat sat.\n")
    build(dir, "--min-bonus 0 --exclude " .. dir .. "/prompts.txt")
    T.eq(newStore(dir):pairBonus("the", "cat", "en"), 0)
    -- Two words in a row shared with the prompt drop both "the cat sat"
    -- lines; "the dog ran" shares none and stays: 8 words, "dog" 3 of
    -- them, and "the" always followed by it.
    build(dir, "--min-bonus 0 --exclude " .. dir .. "/prompts.txt"
        .. " --exclude-words 2")
    local store = newStore(dir)
    T.eq(store:pairBonus("the", "cat", "en"), 0)
    T.eq(store:pairBonus("the", "dog", "en"), 426)
    remove(dir)
end)

it("gives no bonus from a dictionary without a table", function()
    local dir = newDictionary()
    local store = newStore(dir, false)
    T.eq(store:pairBonus("the", "cat", "en"), 0)
    remove(dir)
end)

it("rereads rows once it holds too many", function()
    local dir = newDictionary()
    build(dir, "--min-bonus 0")
    local store = newStore(dir)
    store.PAIR_ROWS = 2
    T.eq(store:pairBonus("the", "cat", "en"), 493)
    store:pairBonus("a", "dog", "en")
    store:pairBonus("cat", "sat", "en")
    T.eq(store.pair_cache.en.size, 1, "started over")
    T.eq(store:pairBonus("the", "cat", "en"), 493)
    remove(dir)
end)

it("gives the keyboard the learned and table bonus together", function()
    local InputController = T.load("input_controller")
    local model = ContextModel:new(newSettings(), "pairs")
    model:learn("the", "cat")
    local asked
    local store = {
        pairBonus = function(_, previous, word, dictionary)
            asked = dictionary
            return previous == "the" and word == "cat" and 500 or 0
        end,
    }
    local controller = InputController:new(model, T.normalization,
        { dbg = function() end }, {}, {}, store, {}, {})
    T.eq(controller:contextBonus("the", "cat", "en"), 1100)
    T.eq(asked, "en")
    T.eq(controller:contextBonus("the", "dog", "en"), 0)
end)
