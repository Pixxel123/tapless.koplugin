local T = require("helper")
local it = T.it

-- Stand-ins for KOReader's gesture detector: a second contact is paired
-- with the first one as its buddy, as KOReader does for two-finger
-- gestures.
local function setup(swiping)
    local Contact = {}
    function Contact.panState() end
    function Contact.tapState() end
    local GestureDetector = { dropped = {} }
    function GestureDetector:newContact(slot)
        local contact = setmetatable({ slot = slot, ges_dec = self,
            state = Contact.tapState, buddy_contact = self.first },
            { __index = Contact })
        if self.first then
            self.first.buddy_contact = contact
        end
        return contact
    end
    function GestureDetector:dropContact(contact)
        table.insert(self.dropped, contact)
    end
    local installed = T.load("stray_touches").install{
        gesture_detector = GestureDetector,
        logger = { warn = function() end },
        swiping = function() return swiping end,
    }
    local function first(state)
        GestureDetector.first = { down = true, state = Contact[state] }
        return GestureDetector.first
    end
    return GestureDetector, first, installed
end

it("ignores a second finger while a swipe is under way", function()
    local detector, first, installed = setup(true)
    T.truthy(installed)
    local swipe = first("panState")
    local stray = detector:newContact(1)
    T.eq(swipe.buddy_contact, nil)
    T.eq(stray.buddy_contact, nil)
    stray.current_tev = { id = 5, x = 1, y = 1 }
    T.eq(stray.state(stray), nil)
    T.eq(#detector.dropped, 0)
    stray.current_tev = { id = -1 }
    stray.state(stray)
    T.eq(detector.dropped[1], stray)
end)

it("pairs fingers as usual when the keyboard is not showing", function()
    local detector, first = setup(false)
    local swipe = first("panState")
    local second = detector:newContact(1)
    T.eq(swipe.buddy_contact, second)
    T.eq(second.buddy_contact, swipe)
end)

it("pairs fingers as usual before the first one moves", function()
    local detector, first = setup(true)
    local touch = first("tapState")
    local second = detector:newContact(1)
    T.eq(touch.buddy_contact, second)
end)
