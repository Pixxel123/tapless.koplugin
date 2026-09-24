-- Tapless swipe test recorder. tools/swipe_session.py installs this as a
-- KOReader user patch for the length of a test session; it is not part of
-- the plugin. It does nothing unless tapless-dev/recording exists.
local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local dev_dir = DataStorage:getDataDir() .. "/tapless-dev"
local flag_path = dev_dir .. "/recording"

local function recording()
    return lfs.attributes(flag_path, "mode") == "file"
end

if not recording() then
    return
end

local function readLines(path)
    local lines = {}
    local file = io.open(path, "r")
    if file then
        for line in file:lines() do
            lines[#lines + 1] = line
        end
        file:close()
    end
    return lines
end

local function keyRects(keyboard)
    local keys = {}
    for row_index, row in ipairs(keyboard.layout or {}) do
        for _, key in ipairs(row) do
            local dimen = key.dimen
            if dimen then
                keys[#keys + 1] = {
                    row = row_index,
                    key = type(key.key) == "string" and key.key or nil,
                    label = type(key.label) == "string" and key.label or nil,
                    candidate = key.is_swype_candidate or nil,
                    x = dimen.x, y = dimen.y, w = dimen.w, h = dimen.h,
                }
            end
        end
    end
    return keys
end

local function findUpvalue(fn, wanted)
    for index = 1, 100 do
        local name, value = debug.getupvalue(fn, index)
        if not name then
            return
        end
        if name == wanted then
            return value
        end
    end
end

-- Prompted words are not what the tester would type, so the keyboard must
-- not learn which words follow which, or which words are used, from them.
-- Returns a function that turns learning back on.
local function pauseLearning(VirtualKeyboard)
    local adapter = type(VirtualKeyboard._swypeCommitPendingContext)
            == "function"
        and findUpvalue(VirtualKeyboard._swypeCommitPendingContext, "adapter")
    local controller = type(adapter) == "table" and adapter.input_controller
    local paused = {}
    for _, name in ipairs({ "context_model", "usage_model" }) do
        local model = controller and controller[name]
        if type(model) == "table" and model.learn then
            model.learn = function() end
            paused[#paused + 1] = model
        else
            logger.warn("Tapless recorder: cannot pause learning", name)
        end
    end
    return function()
        for _, model in ipairs(paused) do
            model.learn = nil
        end
    end
end

local function install()
    local VirtualKeyboard = require("ui/widget/virtualkeyboard")
    if not VirtualKeyboard._tapless_adapter_installed then
        logger.warn("Tapless recorder: Tapless keyboard is not active")
        return
    end
    local Device = require("device")
    local Notification = require("ui/widget/notification")
    local json = require("dkjson")
    local time = require("ui/time")
    local Recorder = dofile(dev_dir .. "/recorder.lua")

    local mode = readLines(dev_dir .. "/mode")[1] or "words"
    local resumeLearning = pauseLearning(VirtualKeyboard)
    local log = assert(io.open(dev_dir .. "/session.jsonl", "a"))
    local active = true
    local toast
    local current_keyboard
    -- The window KOReader sends gestures to: the topmost one that is not a
    -- toast, with "+toast" when a toast is shown above it.
    local function topWindow(stack)
        local toast_shown = false
        for index = #(stack or {}), 1, -1 do
            local widget = stack[index].widget
            if widget.toast then
                toast_shown = true
            else
                local label = widget == current_keyboard and "keyboard"
                    or widget.name or "other"
                return toast_shown and label .. "+toast" or label
            end
        end
        return "none"
    end

    local function stop(reason)
        if not active then
            return
        end
        active = false
        resumeLearning()
        if toast then
            UIManager:close(toast)
            toast = nil
        end
        log:close()
        logger.info("Tapless recorder: stopped", reason)
    end

    local recorder = Recorder:new{
        prompts = Recorder.parsePrompts(
            readLines(dev_dir .. "/prompts.txt"), mode),
        mode = mode,
        now = function() return time.now() end,
        write = function(record)
            log:write(json.encode(record), "\n")
            log:flush()
        end,
        show = function(text)
            if toast then
                UIManager:close(toast)
            end
            toast = Notification:new{ text = text, timeout = false }
            UIManager:show(toast)
        end,
    }

    -- Runs a recorder call; any error stops recording, never typing.
    local function safely(fn, ...)
        if not active then
            return
        end
        local ok, err = pcall(fn, ...)
        if not ok then
            logger.warn("Tapless recorder: stopped after error", err)
            stop("error")
        end
    end

    local function checkFlag()
        if active and not recording() then
            stop("flag removed")
        end
    end

    local function wrap(name, wrapper)
        local original = assert(VirtualKeyboard[name],
            "Tapless recorder: VirtualKeyboard." .. name .. " missing")
        VirtualKeyboard[name] = function(...)
            return wrapper(original, ...)
        end
    end

    local gestures = {
        onSwypeWordPan = "pan",
        onSwypeWordPanRelease = "pan_release",
        onSwypeWordSwipe = "swipe",
        onSwypeWordMultiswipe = "multiswipe",
    }
    for name, kind in pairs(gestures) do
        wrap(name, function(original, keyboard, arg, ges, source_key)
            if kind == "pan" and not (recorder.events) then
                checkFlag()
            end
            safely(function()
                recorder:gesture(kind, ges,
                    source_key and type(source_key.key) == "string"
                        and source_key.key or nil)
            end)
            local handled = original(keyboard, arg, ges, source_key)
            if not handled then
                safely(function() recorder:dropGesture() end)
            end
            return handled
        end)
    end

    wrap("_swypePickCandidates", function(original, keyboard, ...)
        local candidates = original(keyboard, ...)
        safely(function() recorder:candidates(candidates) end)
        return candidates
    end)

    wrap("_swypeFinalizeSignature",
            function(original, keyboard, signature, trace_info)
        -- Read the keys before the word goes in: typing it can rebuild
        -- the keyboard, and keys not laid out again yet read as 0, 0.
        local ok, keys = pcall(keyRects, keyboard)
        local result = original(keyboard, signature, trace_info)
        checkFlag()
        safely(function()
            recorder:finalize(signature, trace_info, {
                dictionary = keyboard.swype_mvp_dictionary or "en",
                keys = ok and keys or {},
            })
        end)
        return result
    end)

    wrap("_swypeSelectCandidate", function(original, keyboard, candidate)
        local index
        local shown = keyboard.swype_mvp_session
            and keyboard.swype_mvp_session:getCandidates()
        for position, item in ipairs(shown or {}) do
            if not index and candidate and (item == candidate
                    or item.word == candidate.word) then
                index = position
            end
        end
        local result = original(keyboard, candidate)
        safely(function()
            recorder:picked(index, candidate and candidate.word)
        end)
        return result
    end)

    wrap("delChar", function(original, keyboard, ...)
        local undoable = keyboard.swype_mvp_session
            and keyboard.swype_mvp_session:getLastInsert() ~= nil
        local result = original(keyboard, ...)
        if undoable then
            safely(function() recorder:deleted() end)
        end
        return result
    end)

    wrap("onShow", function(original, keyboard, ...)
        current_keyboard = keyboard
        local result = original(keyboard, ...)
        safely(function() recorder:showPrompt() end)
        return result
    end)

    local ok, meta = pcall(dofile,
        DataStorage:getDataDir() .. "/plugins/tapless.koplugin/_meta.lua")
    -- Log every gesture before any widget sees it, to find out where the
    -- rest of a swipe goes when the keyboard stops receiving it.
    local original_send = UIManager.sendEvent
    function UIManager:sendEvent(event, ...)
        if active and event and event.handler == "onGesture" then
            safely(function()
                recorder:dispatched(event.args and event.args[1],
                    topWindow(self._window_stack))
            end)
        end
        return original_send(self, event, ...)
    end

    safely(function()
        recorder:start{
            screen = { Device.screen:getWidth(), Device.screen:getHeight() },
            model = Device.model,
            plugin_version = ok and type(meta) == "table"
                and meta.version or nil,
        }
    end)
    logger.info("Tapless recorder: recording", mode)
end

UIManager:nextTick(function()
    local ok, err = pcall(install)
    if not ok then
        logger.warn("Tapless recorder: not installed", err)
    end
end)
