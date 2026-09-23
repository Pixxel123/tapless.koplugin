local T = require("helper")
local it = T.it

local ROOT = "/tmp/claude-1000/tapless-registry-spec"
local scans = 0

-- KOReader's lfs, on the real file system, counting folder scans.
package.preload["libs/libkoreader-lfs"] = function()
    local lfs = {}
    function lfs.attributes(path, field)
        local pipe = io.popen("stat -c '%F %Y' '" .. path .. "' 2>/dev/null")
        local kind, modified = (pipe:read("*l") or ""):match("^(.-) (%d+)$")
        pipe:close()
        if not kind then
            return nil
        end
        local attributes = {
            mode = kind == "directory" and "directory" or "file",
            modification = tonumber(modified),
        }
        if field then
            return attributes[field]
        end
        return attributes
    end
    function lfs.dir(path)
        scans = scans + 1
        local pipe = io.popen("ls -a '" .. path .. "'")
        return function()
            local name = pipe:read("*l")
            if not name then
                pipe:close()
            end
            return name
        end
    end
    return lfs
end
package.preload["datastorage"] = function()
    return { getDataDir = function() return ROOT .. "/data" end }
end

local function addDictionary(folder, id, modified)
    local path = folder .. "/" .. id
    os.execute("mkdir -p " .. path)
    for _, name in ipairs({ "words.buckets.tsv", "words.buckets.idx",
            "words.popular.tsv", "words.popular.idx" }) do
        io.open(path .. "/" .. name, "w"):close()
    end
    local manifest = io.open(path .. "/manifest.tsv", "w")
    manifest:write("id\t" .. id .. "\nname\t" .. id:upper() .. "\n")
    manifest:close()
    os.execute("touch -d @" .. modified .. " " .. folder)
end

local function fresh()
    os.execute("rm -rf " .. ROOT)
    os.execute("mkdir -p " .. ROOT .. "/data/swype/dictionaries "
        .. ROOT .. "/plugin/dictionaries")
    addDictionary(ROOT .. "/plugin/dictionaries", "en", 1000)
    os.execute("touch -d @1000 " .. ROOT .. "/data/swype/dictionaries")
    scans = 0
    return T.load("dictionary_registry")
end

local function ids(list)
    local result = {}
    for index, descriptor in ipairs(list) do
        result[index] = descriptor.id
    end
    return table.concat(result, ",")
end

it("reads the dictionary folders once while they are unchanged", function()
    local registry = fresh()
    T.eq(ids(registry:list(ROOT .. "/plugin")), "en")
    local after_first = scans
    T.eq(ids(registry:list(ROOT .. "/plugin")), "en")
    T.eq(registry:get("en", ROOT .. "/plugin").name, "EN")
    T.eq(scans, after_first, "no rescan")
end)

it("sees a dictionary added to a folder", function()
    local registry = fresh()
    registry:list(ROOT .. "/plugin")
    addDictionary(ROOT .. "/data/swype/dictionaries", "pl", 2000)
    T.eq(ids(registry:list(ROOT .. "/plugin")), "en,pl")
    T.eq(registry:get("pl", ROOT .. "/plugin").name, "PL")
end)

it("rereads the folders when told the dictionaries changed", function()
    local registry = fresh()
    registry:list(ROOT .. "/plugin")
    local after_first = scans
    registry:invalidate()
    registry:list(ROOT .. "/plugin")
    T.truthy(scans > after_first)
end)
