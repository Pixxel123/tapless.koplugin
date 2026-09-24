local UsageModel = {
    -- The most uses counted for one word, and the most words kept.
    MAX_USES = 255,
    MAX_WORDS = 2000,
}
UsageModel.__index = UsageModel

function UsageModel:new(settings, setting_key)
    return setmetatable({
        settings = assert(settings),
        setting_key = assert(setting_key),
        counts = nil,
        size = 0,
        dirty = false,
    }, self)
end

function UsageModel:getCounts()
    if self.counts then
        return self.counts
    end
    local counts = self.settings:readSetting(self.setting_key, {})
    if type(counts) ~= "table" then
        counts = {}
    end
    local size = 0
    for _ in pairs(counts) do
        size = size + 1
    end
    self.counts = counts
    self.size = size
    return counts
end

-- How many times the word has been kept, a pick counting for more.
function UsageModel:uses(word)
    return self:getCounts()[word] or 0
end

function UsageModel:learn(word, uses)
    if type(word) ~= "string" or #word == 0 then
        return
    end
    local counts = self:getCounts()
    if not counts[word] then
        self.size = self.size + 1
    end
    counts[word] = math.min(self.MAX_USES, (counts[word] or 0) + (uses or 1))
    if self.size > self.MAX_WORDS then
        local least_word
        local least_count
        for candidate_word, candidate_count in pairs(counts) do
            if candidate_word ~= word
                    and (not least_count or candidate_count < least_count) then
                least_word = candidate_word
                least_count = candidate_count
            end
        end
        if least_word then
            counts[least_word] = nil
            self.size = self.size - 1
        end
    end
    self.dirty = true
end

-- Counts the word a swipe typed once it is left in the text. A pick counts
-- when it is chosen and sets the flag itself.
function UsageModel:commit(pending)
    if not pending or pending.usage_committed then
        return
    end
    self:learn(pending.word, 1)
    pending.usage_committed = true
end

function UsageModel:save()
    if self.dirty and self.counts then
        self.settings:saveSetting(self.setting_key, self.counts)
        self.dirty = false
    end
end

return UsageModel
