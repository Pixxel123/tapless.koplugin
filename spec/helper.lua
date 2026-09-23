local T = { passed = 0, failed = 0 }

package.preload["ffi/utf8proc"] = function()
    return { lowercase_dumb = function(text) return text:lower() end }
end

function T.load(module)
    return dofile(T.plugin_dir .. "/" .. module .. ".lua")
end

function T.eq(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ") .. ": expected "
            .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

function T.truthy(value, message)
    if not value then
        error(message or "expected a truthy value", 2)
    end
end

local current_file
function T.it(name, fn)
    local ok, err = pcall(fn)
    if ok then
        T.passed = T.passed + 1
        print("  ok   " .. name)
    else
        T.failed = T.failed + 1
        print("  FAIL " .. name .. "\n       " .. tostring(err))
    end
end

function T.run_file(name)
    current_file = name
    print(name)
    require(name)
end

function T.report()
    print(string.format("\n%d passed, %d failed", T.passed, T.failed))
    return T.failed == 0
end

-- Letters normalize to themselves; anything longer than one character
-- (labels such as "Shift" or the space key) is not a text key.
T.normalization = {
    normalizeText = function(_, text)
        if type(text) == "string" and text:match("^%a$") then
            return text:lower()
        end
        return ""
    end,
    normalizeChar = function(_, char)
        if type(char) == "string" and char:match("^%a$") then
            return char:lower()
        end
    end,
    splitChars = function(_, text)
        local chars = {}
        for char in (text or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            chars[#chars + 1] = char
        end
        return chars
    end,
}

T.gesture_range = {
    new = function(_, options) return options end,
}

return T
