-- Finds a local that a KOReader function captured, to reach classes
-- KOReader does not export (VirtualKey, Contact, VirtualKeyPopup).
return function(fn, wanted)
    for index = 1, 100 do
        local name, value = debug.getupvalue(fn, index)
        if not name then
            break
        end
        if name == wanted then
            return value
        end
    end
end
