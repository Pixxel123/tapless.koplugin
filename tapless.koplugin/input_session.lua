local InputSession = {}
InputSession.__index = InputSession

function InputSession:new()
    return setmetatable({
        candidates = nil,
        last_insert = nil,
        debug_signature = nil,
    }, self)
end

function InputSession:getCandidates()
    return self.candidates
end

function InputSession:getLastInsert()
    return self.last_insert
end

function InputSession:hasCandidateState()
    return self.candidates ~= nil or self.debug_signature ~= nil
end

function InputSession:clear(keep_debug)
    self.candidates = nil
    self.last_insert = nil
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
    local inserted = candidates[1].word .. " "
    self.candidates = candidates
    self.debug_signature = signature
    self.last_insert = {
        text = inserted,
        signature = signature,
        word = candidates[1].word,
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
        replacement = candidate.word .. " ",
        delete_text = self.last_insert.text,
    }
end

return InputSession
