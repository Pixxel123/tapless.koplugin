local InputSession = {}
InputSession.__index = InputSession

function InputSession:new()
    return setmetatable({
        candidates = nil,
        last_insert = nil,
        debug_signature = nil,
        personal_offer = nil,
    }, self)
end

function InputSession:getCandidates()
    return self.candidates
end

-- Takes a candidate off the suggestions; returns the ones left.
function InputSession:removeCandidate(candidate)
    local remaining = {}
    for _, other in ipairs(self.candidates or {}) do
        if other ~= candidate and other.word ~= candidate.word then
            remaining[#remaining + 1] = other
        end
    end
    if self.candidates then
        self.candidates = remaining
    end
    return remaining
end

function InputSession:getLastInsert()
    return self.last_insert
end

function InputSession:getPersonalOffer()
    return self.personal_offer
end

function InputSession:setPersonalOffer(offer)
    self.personal_offer = offer
end

function InputSession:clearPersonalOffer()
    local had_offer = self.personal_offer ~= nil
    self.personal_offer = nil
    return had_offer
end

function InputSession:hasCandidateState()
    return self.candidates ~= nil or self.debug_signature ~= nil
end

function InputSession:clear(keep_debug)
    self.candidates = nil
    self.last_insert = nil
    self.personal_offer = nil
    if not keep_debug then
        self.debug_signature = nil
    end
end

function InputSession:recordNoCandidate(signature)
    self.debug_signature = signature
    self:clear(true)
end

function InputSession:recordShortSignature(signature)
    self.debug_signature = signature
end

function InputSession:recordInsert(signature, candidates, previous_word)
    if not candidates or #candidates == 0 then
        return
    end
    local output_word = candidates[1].output_word or candidates[1].word
    local inserted = output_word .. " "
    self.candidates = candidates
    self.personal_offer = nil
    self.debug_signature = signature
    self.last_insert = {
        text = inserted,
        signature = signature,
        word = candidates[1].word,
        output_word = output_word,
        previous_word = previous_word,
    }
    return inserted
end

function InputSession:rejection()
    if self.last_insert and self.last_insert.text then
        return {
            handled = true,
            text = self.last_insert.text,
            signature = self.last_insert.signature,
        }
    end
    if self:hasCandidateState() then
        return { handled = true }
    end
    return { handled = false }
end

function InputSession:selection(candidate)
    if not candidate or not self.last_insert then
        return
    end
    return {
        candidate = candidate,
        pending = self.last_insert,
        replacement = (candidate.output_word or candidate.word) .. " ",
        delete_text = self.last_insert.text,
    }
end

return InputSession
