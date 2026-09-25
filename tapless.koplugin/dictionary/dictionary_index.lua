local DictionaryIndex = {}

local function collapseRepeats(signature)
    local has_repeats = false
    for index = 2, #signature do
        if string.byte(signature, index) == string.byte(signature, index - 1) then
            has_repeats = true
            break
        end
    end
    if not has_repeats then
        return signature
    end

    local collapsed = {}
    local repeat_positions
    local previous
    for index = 1, #signature do
        local character = string.sub(signature, index, index)
        if character == previous then
            repeat_positions = repeat_positions or {}
            local position = #collapsed
            repeat_positions[position] = (repeat_positions[position] or 0) + 1
        else
            table.insert(collapsed, character)
            previous = character
        end
    end
    return table.concat(collapsed), repeat_positions
end

local function indexPattern(key_length)
    if key_length == 1 then
        return "^([a-z])\t([0-9]+)\t([0-9]+)\t([0-9]+)$"
    end
    return "^([a-z][a-z])\t([0-9]+)\t([0-9]+)\t([0-9]+)$"
end

function DictionaryIndex:parseIndex(data, key_length)
    local index = {}
    local pattern = indexPattern(key_length)
    for line in (data or ""):gmatch("[^\r\n]+") do
        local key, offset, bytes, rows = line:match(pattern)
        if key then
            index[key] = {
                offset = tonumber(offset),
                bytes = tonumber(bytes),
                rows = tonumber(rows),
            }
        end
    end
    if not next(index) then
        return nil
    end
    return index
end

function DictionaryIndex:loadIndex(path, key_length)
    local file = io.open(path, "r")
    if not file then
        return nil, "unavailable"
    end
    local data = file:read("*a") or ""
    file:close()
    local index = self:parseIndex(data, key_length)
    if not index then
        return nil, "empty"
    end
    return index
end

function DictionaryIndex:newBucket()
    return {
        entries = {},
        by_gesture_length = {},
    }
end

function DictionaryIndex:addBucketLine(bucket, line)
    local signature, word, freq, lang = (line or ""):match(
        "^([^\t]+)\t([^\t]+)\t([0-9]+)\t([a-z][a-z]*)$")
    if not signature or not word or not freq then
        return
    end
    local gesture_signature, repeat_positions = collapseRepeats(signature)
    local entry = {
        signature = signature,
        gesture_signature = gesture_signature,
        repeat_positions = repeat_positions,
        word = word,
        freq = tonumber(freq) or 0,
        lang = lang,
    }
    table.insert(bucket.entries, entry)
    local gesture_length = #gesture_signature
    bucket.by_gesture_length[gesture_length] =
        bucket.by_gesture_length[gesture_length] or {}
    table.insert(bucket.by_gesture_length[gesture_length], entry)
    return entry
end

function DictionaryIndex:parseBucket(data, bucket)
    bucket = bucket or self:newBucket()
    for line in (data or ""):gmatch("[^\n]+") do
        self:addBucketLine(bucket, line)
    end
    return bucket
end

function DictionaryIndex:readBucket(file, meta)
    local bucket = self:newBucket()
    if not file or not meta then
        return bucket
    end
    file:seek("set", meta.offset)
    local data = file:read(meta.bytes) or ""
    return self:parseBucket(data, bucket)
end

return DictionaryIndex
