-- A second finger that touches the screen while a swipe is under way on the
-- keyboard, such as a thumb resting near the edge while holding the device,
-- is ignored until it lifts. KOReader would otherwise pair the two contacts
-- into a two-finger gesture, and the swipe would end part-way through.

local StrayTouches = {}

local findUpvalue = dofile((debug.getinfo(1, "S").source
    :match("^@(.+)/[^/]+%.lua$") or ".") .. "/find_upvalue.lua")

-- options: gesture_detector, logger, and swiping() telling whether touches
-- currently go to a keyboard that takes swipes.
function StrayTouches.install(options)
    local GestureDetector = assert(options.gesture_detector)
    if GestureDetector._tapless_stray_touches then
        return true
    end
    local Contact = findUpvalue(GestureDetector.newContact, "Contact")
    if type(Contact) ~= "table" or type(Contact.panState) ~= "function" then
        options.logger.warn("Tapless: cannot ignore stray touches")
        return false
    end
    GestureDetector._tapless_stray_touches = true
    local swiping = assert(options.swiping)

    local function ignoredState(contact)
        local tev = contact.current_tev
        if tev and tev.id == -1 then
            contact.ges_dec:dropContact(contact)
        end
    end

    local original_new_contact = GestureDetector.newContact
    function GestureDetector:newContact(slot)
        local contact = original_new_contact(self, slot)
        local swipe = contact.buddy_contact
        if swipe and swipe.down and swipe.state == Contact.panState
                and swiping() then
            swipe.buddy_contact = nil
            contact.buddy_contact = nil
            contact.state = ignoredState
        end
        return contact
    end
    return true
end

return StrayTouches
