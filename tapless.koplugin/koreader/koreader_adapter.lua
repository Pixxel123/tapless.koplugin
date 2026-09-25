local KoreaderAdapter = {}
KoreaderAdapter.__index = KoreaderAdapter

function KoreaderAdapter:new(options)
    return setmetatable(options, self)
end

function KoreaderAdapter:install(VirtualKeyboard)
    if VirtualKeyboard._tapless_adapter_installed then
        return VirtualKeyboard
    end
    VirtualKeyboard._tapless_adapter_installed = true

    local original_init = assert(VirtualKeyboard.init)
    local original_show = assert(VirtualKeyboard.onShow)
    local original_close_widget = assert(VirtualKeyboard.onCloseWidget)
    local adapter = self

    function VirtualKeyboard:init()
        self.swype_mvp_closed = false
        self.swype_mvp_session = self.swype_mvp_session
            or adapter.input_session:new()
        self.swype_mvp_prefetch_controller = self.swype_mvp_prefetch_controller
            or adapter.prefetch_controller:new(
                adapter.dictionary_store,
                adapter.ui_manager,
                function() return self.swype_mvp_trace ~= nil end,
                adapter.prefetch_batch_size,
                adapter.prefetch_work_ms)
        adapter.dictionary_controller:initialize(self)
        original_init(self)
    end

    function VirtualKeyboard:addKeys()
        adapter.key_adapter:ensureInstalled()
        self:free()
        self.layout = {}
        self.swype_mvp_handle = nil
        local row_count = #self.KEYS + 1
        local screen = self:_swypeScreen()
        -- One-handed, the keys block has its own place and size; while
        -- resizing, the draft's.
        local resize = self.swype_mvp_resize
        local block = resize and resize.draft
        if not block then
            local state = adapter.one_handed:state(screen)
            block = state.enabled and state or nil
        end
        self.height = block and block.height
            and adapter.one_handed.toPx(block.height, screen)
            or self:_swypeNormalHeight()
        local border = adapter.size.border.default
        local inset = border + self.padding
        local area = block
            and adapter.one_handed.layout(block, screen, inset)
        -- One-handed, only the keys frame is drawn: area.frame_w wide, at
        -- area.frame_x. The page shows beside it.
        local inner_w = area and area.inner_w or self.width - 2 * inset
        local inner_h = self.height - 2 * inset
        local keys_width = area
            and inner_w + 2 * self.padding + 2 * self.key_padding
            or self.width
        local base_key_width = math.floor((keys_width
            - (#self.KEYS[1] + 1) * self.key_padding - 2 * self.padding)
            / #self.KEYS[1])
        local base_key_height = math.floor((self.height
            - (row_count + 1) * self.key_padding - 2 * self.padding)
            / row_count)
        local h_key_padding = adapter.horizontal_span:new{
            width = self.key_padding,
        }
        local v_key_padding = adapter.vertical_span:new{
            width = self.key_padding,
        }
        local vertical_group = adapter.vertical_group:new{
            allow_mirroring = false,
        }
        local handle = area and self:_swypeHandle(base_key_width,
            base_key_height, block, screen)
        self.swype_mvp_handle = handle or nil
        local candidate_row = adapter.keyboard_ui:createCandidateRow(self, {
            width = keys_width,
            height = base_key_height,
            key_padding = self.key_padding,
            padding = self.padding,
            horizontal_padding = h_key_padding,
            handle = handle and { widget = handle, width = base_key_width,
                side = area.handle_side } or nil,
        })
        self.swype_mvp_candidate_keys = candidate_row.keys
        table.insert(vertical_group, candidate_row.widget)
        table.insert(self.layout, candidate_row.layout)
        table.insert(vertical_group, v_key_padding)

        for row_index = 1, #self.KEYS do
            local horizontal_group = adapter.horizontal_group:new{
                allow_mirroring = false,
            }
            local layout_row = {}
            for key_index = 1, #self.KEYS[row_index] do
                local definition = self.KEYS[row_index][key_index]
                local key_chars = definition[self.keyboard_layer]
                local key
                local label
                local alt_label
                local width_factor
                if type(key_chars) == "table" then
                    key = key_chars[1]
                    label = key_chars.label
                    alt_label = key_chars.alt_label
                    width_factor = key_chars.width
                else
                    key = key_chars
                    key_chars = nil
                end
                width_factor = width_factor or definition.width
                    or self.KEYS[row_index].width or 1.0
                local key_width = math.floor(
                    (base_key_width + self.key_padding) * width_factor)
                    - self.key_padding
                label = label or definition.label or key
                if label == "" and self.shiftmode
                        and (not self.release_shift or self.symbolmode) then
                    key = label
                    label = ""
                end
                local is_space = key == " "
                if is_space then
                    alt_label = self:_swypeDictionaryLabel()
                end
                local is_globe = self.utf8mode_keys[label] ~= nil
                if is_globe then
                    alt_label = adapter.one_handed.HINT
                end
                local virtual_key = adapter.virtual_key:new{
                    key = key,
                    key_chars = key_chars,
                    icon = definition.icon,
                    label = label,
                    alt_label = alt_label,
                    bold = definition.bold,
                    keyboard = self,
                    width = key_width,
                    height = base_key_height,
                }
                if not virtual_key.key_chars and label ~= "" then
                    virtual_key.swipe_callback = nil
                end
                if is_space then
                    self.swype_mvp_language_key = virtual_key
                    -- With one language, holding space just types a space
                    -- when the finger lifts.
                    virtual_key.hold_callback = function()
                        if self:_swypeToggleDictionary() then
                            virtual_key.ignore_key_release = true
                        end
                    end
                    virtual_key.hold_cb_is_popup = false
                end
                if is_globe then
                    self:_swypeWireGlobeKey(virtual_key)
                end
                table.insert(horizontal_group, virtual_key)
                table.insert(layout_row, virtual_key)
                if key_index ~= #self.KEYS[row_index] then
                    table.insert(horizontal_group, h_key_padding)
                end
            end
            table.insert(vertical_group, horizontal_group)
            table.insert(self.layout, layout_row)
            if row_index ~= #self.KEYS then
                table.insert(vertical_group, v_key_padding)
            end
        end

        local keyboard_frame = adapter.frame_container:new{
            margin = 0,
            bordersize = border,
            background = adapter.settings:nilOrTrue("keyboard_key_border")
                and adapter.blitbuffer.COLOR_LIGHT_GRAY
                or adapter.blitbuffer.COLOR_WHITE,
            radius = 0,
            padding = self.padding,
            allow_mirroring = false,
            adapter.center_container:new{
                dimen = adapter.geometry:new{ w = inner_w, h = inner_h },
                vertical_group,
            },
        }
        local bottom_child = keyboard_frame
        if area then
            bottom_child = adapter.horizontal_group:new{
                allow_mirroring = false,
                adapter.horizontal_span:new{ width = area.frame_x },
                keyboard_frame,
                adapter.horizontal_span:new{ width = area.after },
            }
        end
        if resize then
            bottom_child = self:_swypeResizeLayer(bottom_child, area,
                inset, inner_w, inner_h)
        end
        self[1] = adapter.bottom_container:new{
            dimen = adapter.screen:getSize(),
            bottom_child,
        }
        keyboard_frame.dimen = keyboard_frame:getSize()
        self.dimen = keyboard_frame.dimen
        adapter.keyboard_ui:registerGestureRanges(self)
    end

    function VirtualKeyboard:_swypeScreen()
        return {
            w = adapter.screen:getWidth(),
            h = adapter.screen:getHeight(),
            dpi = adapter.screen:getDPI(),
        }
    end

    -- The height from Tapless's Keyboard size setting.
    function VirtualKeyboard:_swypeNormalHeight()
        return adapter.screen:scaleBySize(
            adapter.key_adapter:keyHeight() * (#self.KEYS + 1))
    end

    -- The ◨ handle at the end of the suggestion row: tap or hold opens
    -- KOReader's own key popup as one row of leave, move and resize.
    function VirtualKeyboard:_swypeHandle(width, height, block, screen)
        local keyboard = self
        local icon_dir = adapter.icon_dir
        local target = adapter.one_handed.target(block, screen)
        local handle
        local function closePopup()
            if handle.popup then
                adapter.ui_manager:close(handle.popup)
                handle.popup = nil
            end
        end
        local function leave()
            closePopup()
            keyboard:_swypeSetOneHanded(function(one_handed, s)
                one_handed:setEnabled(s, false)
            end)
        end
        local function move()
            closePopup()
            keyboard:_swypeSetOneHanded(function(one_handed, s)
                one_handed:moveToTarget(s)
            end)
        end
        local function resize()
            closePopup()
            keyboard:_swypeStartResize()
        end
        handle = adapter.virtual_key:new{
            key = adapter.one_handed.HINT,
            label = adapter.one_handed.HINT,
            is_tapless_handle = true,
            -- Every entry keeps a plain string key: VirtualKeyPopup's
            -- "key = v.key or v" falls back to the whole table otherwise,
            -- which addChar cannot take a swipe fallback string from.
            -- One row: leave, move under the finger, resize.
            key_chars = {
                [1] = { key = "move",
                    icon = icon_dir .. "/" .. target .. ".svg" },
                west = { key = "leave", icon = icon_dir .. "/leave.svg" },
                west_func = leave,
                east = { key = "resize",
                    icon = icon_dir .. "/resize.svg" },
                east_func = resize,
            },
            keyboard = keyboard,
            width = width,
            height = height,
        }
        -- The callback swap from _swypeWireGlobeKey: while the popup is
        -- built, the centre key reads handle.callback as its own, so it
        -- moves the keys; afterwards it is tap again.
        local tap
        local function open()
            -- Without KOReader's popup class, only the swipes work.
            if not adapter.virtual_key_popup then
                return
            end
            handle.callback = move
            local popup = adapter.virtual_key_popup:new{
                parent_key = handle,
            }
            handle.popup = popup
            -- A tap outside or Back closes it too; forget it either way.
            local closed = popup.onCloseWidget
            popup.onCloseWidget = function(widget)
                if handle.popup == widget then
                    handle.popup = nil
                end
                return closed(widget)
            end
            keyboard:_swypePlainPopup(popup, handle)
            handle.callback = tap
            -- KOReader sets this when it nudges the popup off an edge, to
            -- skip the first lift; ours never opens under the finger.
            handle.ignore_key_release = nil
        end
        tap = open
        handle.callback = tap
        handle.hold_callback = open
        handle.hold_cb_is_popup = true
        -- A swipe towards an option runs it; any other direction must not
        -- fall back to typing the handle's own key.
        local swipes = { west = leave, northwest = leave, north = move,
            east = resize, northeast = resize }
        handle.swipe_callback = function(ges)
            local key_function = swipes[ges.direction]
            if key_function then
                key_function()
            end
        end
        return handle
    end

    -- Redraws KOReader's popup as one white row with thin grey lines
    -- between the keys, just above the keyboard and flush with its edge
    -- at the handle's end. A swipe on one of its keys must not fall back
    -- to typing the key either.
    function VirtualKeyboard:_swypePlainPopup(popup, handle)
        local white = adapter.blitbuffer.COLOR_WHITE
        local position = popup[1]
        local frame = position[1]
        local centre = frame[1]
        local rows = centre[1]
        local row = rows[1]
        local keys = popup.layout[1]
        local line_w = adapter.size.line.medium
        for index = #row, 1, -1 do
            row[index] = nil
        end
        for index, key in ipairs(keys) do
            if index > 1 then
                table.insert(row, adapter.line_widget:new{
                    background = adapter.blitbuffer.COLOR_LIGHT_GRAY,
                    dimen = adapter.geometry:new{
                        w = line_w, h = key.height },
                })
            end
            table.insert(row, key)
            key[1].background = white
            -- KOReader builds icon keys as plain images: without alpha,
            -- which paints our transparent SVGs as black squares, and
            -- kept in their original colours in night mode, which leaves
            -- them black on the inverted keys.
            if key.icon and key[1][1][1] then
                key[1][1][1].alpha = true
                key[1][1][1].original_in_nightmode = false
            end
            key.swipe_callback = nil
            -- KOReader skips the first lift on the centre key, which it
            -- expects under the finger; ours is not.
            if key._onHoldReleaseKey then
                key.onHoldReleaseKey = key._onHoldReleaseKey
                key.onPanReleaseKey = key._onPanReleaseKey
            end
        end
        row:resetLayout()
        rows:resetLayout()

        frame.background = white
        frame.padding = 0
        centre.dimen.w = #keys * handle.width + (#keys - 1) * line_w
        centre.dimen.h = handle.height
        local border = frame.bordersize
        local w = centre.dimen.w + 2 * border
        local h = centre.dimen.h + 2 * border
        -- popup.dimen is this same table, which its refreshes use.
        frame.dimen.w, frame.dimen.h = w, h

        -- self.dimen is the keys frame, placed when it was painted.
        local board, key_box = self.dimen, handle[1].dimen
        -- Flush with the keyboard's edge at the handle's end.
        local x = board.x
        if key_box.x + key_box.w / 2 > board.x + board.w / 2 then
            x = board.x + board.w - w
        end
        position.dimen.x = math.max(0, math.min(x, position.dimen.w - w))
        -- Its bottom border lies on the keyboard's top one, not above it.
        position.dimen.y = math.max(0, board.y - h + border)
    end

    -- Tap 🌐 for KOReader's layout menu, which KOReader opens on hold;
    -- hold it to switch one-handed mode when the finger lifts.
    function VirtualKeyboard:_swypeWireGlobeKey(key)
        local open_menu = key.hold_callback
        if not open_menu then
            return
        end
        local keyboard = self
        local function close_popup()
            if key.popup then
                adapter.ui_manager:close(key.popup)
            end
        end
        local function tap()
            -- The layout popup's centre key runs this key's tap action,
            -- read while the popup is built: there it closes the popup.
            key.callback = close_popup
            open_menu()
            -- KOReader sets this when the popup is clamped at the screen
            -- edge, to swallow the hold-release under a finger still down
            -- from opening it. No finger is down after a tap.
            key.ignore_key_release = nil
            key.callback = tap
        end
        key.callback = tap
        -- Switching may rebuild the dialog and its keyboard, which must not
        -- happen under a finger that is still down.
        key.hold_callback = function()
            keyboard.swype_mvp_switch_on_lift = true
        end
        key.hold_cb_is_popup = false
    end

    function VirtualKeyboard:_swypeTakeLift()
        if not self.swype_mvp_switch_on_lift then
            return false
        end
        self.swype_mvp_switch_on_lift = nil
        self:_swypeSetOneHanded(function(one_handed, screen)
            one_handed:toggle(screen)
        end)
        return true
    end

    -- Saves a one-handed change through change(one_handed, screen), then
    -- rebuilds the keys.
    function VirtualKeyboard:_swypeSetOneHanded(change)
        change(adapter.one_handed, self:_swypeScreen())
        self:_swypeRebuild()
    end

    -- Rebuilds the keys from the saved state. A new height goes through the
    -- dialog, which builds a new keyboard from the saved settings, so this
    -- one is not touched after that. Otherwise, the keys frame may have
    -- moved or changed width, so the whole bottom band repaints, not just
    -- its own (possibly stale) dimen.
    function VirtualKeyboard:_swypeRebuild()
        local old_height = self.height
        self:_swypeReset()
        self:addKeys()
        local parent = self.inputbox and self.inputbox.parent
        if self.height ~= old_height and parent
                and parent.onKeyboardHeightChanged then
            parent:onKeyboardHeightChanged()
            return
        end
        local tallest = math.max(old_height, self.height)
        adapter.ui_manager:setDirty("all", "flashui", adapter.geometry:new{
            x = 0,
            y = adapter.screen:getHeight() - tallest,
            w = self.width,
            h = tallest,
        })
    end

    -- Resize mode starts from the saved block at its actual height, which
    -- may be nil for the normal height; the frame draws over it.
    function VirtualKeyboard:_swypeStartResize()
        local screen = self:_swypeScreen()
        local state = adapter.one_handed:state(screen)
        self.swype_mvp_resize = {
            draft = {
                left = state.left,
                width = state.width,
                height = state.height,
            },
            start_height = self.height,
        }
        self:_swypeReset()
        self:addKeys()
        self:_refresh(true)
    end

    -- The faded keys take no gestures while resizing; the frame over them
    -- takes the drags.
    function VirtualKeyboard:_swypeResizeLayer(bottom_child, area, inset,
            inner_w, inner_h)
        local keyboard = self
        for _, row in ipairs(self.layout) do
            for _, key in ipairs(row) do
                key.ges_events = {}
            end
        end
        if self.swype_mvp_handle then
            self.swype_mvp_handle.ges_events = {}
        end
        local frame = adapter.resize_frame:create(self, {
            width = self.width,
            height = self.height,
            keys = { x = area.frame_x + inset, y = inset,
                w = inner_w, h = inner_h },
            fade = { x = area.frame_x + inset, y = inset,
                w = inner_w, h = inner_h },
            on_reset = function() keyboard:_swypeResetResize() end,
            on_done = function() keyboard:_swypeFinishResize() end,
        })
        return adapter.overlap_group:new{
            allow_mirroring = false,
            bottom_child,
            frame,
        }
    end

    function VirtualKeyboard:_swypeResizeDrag()
        local screen = self:_swypeScreen()
        local one_handed = adapter.one_handed
        -- Only a top-corner drag from a nil (normal) height needs this, to
        -- have a number to drag from.
        local normal_height = one_handed.toMM(
            self:_swypeNormalHeight(), screen)
        return function(start, grip, dx, dy)
            return one_handed.drag(start, grip, one_handed.toMM(dx, screen),
                one_handed.toMM(dy, screen), screen, normal_height)
        end
    end

    -- Rebuilds the faded keys at the draft. A shorter keyboard uncovers
    -- part of the dialog, so everything over the taller height repaints.
    function VirtualKeyboard:_swypeRedrawResize()
        if not self.swype_mvp_resize then
            return
        end
        local old_height = self.height
        self:addKeys()
        local tallest = math.max(old_height, self.height)
        adapter.ui_manager:setDirty("all", "ui", adapter.geometry:new{
            x = 0,
            y = adapter.screen:getHeight() - tallest,
            w = self.width,
            h = tallest,
        })
    end

    function VirtualKeyboard:_swypeResizePan(ges)
        local resize = self.swype_mvp_resize
        if not resize or not ges then
            return false
        end
        if not resize.drag and not adapter.resize_frame:begin(resize,
                ges.start_pos or ges.pos) then
            return false
        end
        if adapter.resize_frame:track(resize, ges.pos,
                self:_swypeResizeDrag()) then
            local keyboard = self
            adapter.resize_frame:queueRedraw(resize, function()
                keyboard:_swypeRedrawResize()
            end)
        end
        return true
    end

    function VirtualKeyboard:_swypeResizeRelease(ges)
        local resize = self.swype_mvp_resize
        if not resize or not ges then
            return false
        end
        if not resize.drag then
            -- A quick flick arrives as one swipe, from where it started.
            if ges.ges ~= "swipe"
                    or not adapter.resize_frame:begin(resize, ges.pos) then
                return false
            end
        end
        adapter.resize_frame:finish(resize, ges.end_pos or ges.pos,
            self:_swypeResizeDrag())
        adapter.resize_frame:cancelRedraw(resize)
        self:_swypeRedrawResize()
        return true
    end

    function VirtualKeyboard:_swypeResetResize()
        local resize = self.swype_mvp_resize
        if not resize then
            return
        end
        adapter.resize_frame:cancelRedraw(resize)
        local screen = self:_swypeScreen()
        resize.draft = adapter.one_handed.reset(resize.draft, screen)
        self:_swypeRedrawResize()
    end

    function VirtualKeyboard:_swypeFinishResize()
        local resize = self.swype_mvp_resize
        if not resize then
            return
        end
        adapter.resize_frame:cancelRedraw(resize)
        self.swype_mvp_resize = nil
        local screen = self:_swypeScreen()
        local normal = adapter.one_handed.toMM(self:_swypeNormalHeight(),
            screen)
        local draft = resize.draft
        adapter.one_handed:update(screen, function(state)
            state.enabled = true
            state.left = draft.left
            state.width = draft.width
            -- Left at the normal height, the keys follow Tapless's
            -- Keyboard size setting.
            state.height = draft.height
                and math.abs(draft.height - normal) >= 0.5
                and draft.height or nil
        end)
        -- Only the keys were redrawn while resizing: measure any height
        -- change from before it began.
        self.height = resize.start_height
        self:_swypeRebuild()
    end

    function VirtualKeyboard:_swypeScheduleWarmUp(delay)
        adapter.dictionary_controller:scheduleWarmUp(self, delay)
    end

    function VirtualKeyboard:onShow()
        self.swype_mvp_closed = false
        local result = original_show(self)
        self:_swypeScheduleWarmUp()
        adapter.dictionary_controller:scheduleLanguageSetup(self)
        return result
    end

    function VirtualKeyboard:onCloseWidget()
        self.swype_mvp_closed = true
        self.swype_mvp_pending_space = nil
        self.swype_mvp_tapped_word = nil
        self.swype_mvp_switch_on_lift = nil
        if self.swype_mvp_resize then
            adapter.resize_frame:cancelRedraw(self.swype_mvp_resize)
            self.swype_mvp_resize = nil
        end
        self:_swypeReset()
        adapter.dictionary_controller:stopWarmUp(self)
        self:_swypeCancelBucketPrefetch()
        self:_swypeCommitPendingContext()
        self:_swypeSaveContext()
        self:_swypeClearCandidateState()
        return original_close_widget(self)
    end

    function VirtualKeyboard:isSwypeMvpEnabled()
        return adapter.settings:nilOrTrue("keyboard_swype_mvp_enabled")
            and not self.symbolmode and not self.umlautmode
            and not self.swype_mvp_resize
    end

    function VirtualKeyboard:_swypeKeyAt(pos)
        return adapter.keyboard_geometry:keyAt(
            self.layout, pos, self.swype_mvp_normalization_profile)
    end

    -- Like _swypeKeyAt, but a start on a number key counts as a start on the
    -- letter key below it.
    function VirtualKeyboard:_swypeStartKeyAt(pos)
        return adapter.keyboard_geometry:startKeyAt(
            self.layout, pos, self.swype_mvp_normalization_profile)
    end

    function VirtualKeyboard:_swypeEndpointLetters(pos, exact_last)
        return adapter.keyboard_geometry:endpointLetters(
            self.layout, pos, exact_last,
            self.swype_mvp_normalization_profile)
    end

    function VirtualKeyboard:_swypeDrawTraceSegment(previous, current)
        adapter.trace_renderer:drawSegment(
            self.swype_mvp_trace, previous, current)
    end

    function VirtualKeyboard:_swypeClearTracePixels(refresh_type)
        adapter.trace_renderer:clear(self.swype_mvp_trace, refresh_type)
    end

    function VirtualKeyboard:_swypeCancelBucketPrefetch()
        self.swype_mvp_prefetch_controller:cancel()
    end

    function VirtualKeyboard:_swypeScheduleBucketPrefetch()
        local trace = self.swype_mvp_trace
        local priority_lasts
        if trace and trace.points and #trace.points > 0
                and trace.letters and #trace.letters > 0 then
            priority_lasts = adapter.keyboard_geometry:endpointLetters(
                self.layout, trace.points[#trace.points],
                trace.letters[#trace.letters],
                self.swype_mvp_normalization_profile)
        end
        self.swype_mvp_prefetch_controller:schedule(
            trace, self.swype_mvp_dictionary or "en", priority_lasts)
    end

    function VirtualKeyboard:_swypeReset(keep_prefetch)
        adapter.gesture_controller:reset(self, keep_prefetch)
    end

    function VirtualKeyboard:_swypePickCandidates(signature, limit, trace_info)
        local key_centers = trace_info
            and adapter.keyboard_geometry:keyCenters(
                self.layout, self.swype_mvp_normalization_profile) or {}
        return adapter.recognition_engine:pickCandidates{
            signature = signature,
            limit = limit,
            dictionary = self.swype_mvp_dictionary or "en",
            trace_info = trace_info,
            key_centers = key_centers,
            start_letters = function(first)
                return adapter.keyboard_geometry:startLetters(self.layout,
                    trace_info.points and trace_info.points[1], first,
                    self.swype_mvp_normalization_profile)
            end,
            endpoint_letters = function(last)
                return self:_swypeEndpointLetters(
                    trace_info.endpoint_pos, last)
            end,
            context_bonus = function(previous_word, word)
                return self:_swypeContextBonus(previous_word, word)
            end,
            word_uses = function(word)
                return self:_swypeWordUses(word)
            end,
            normalization_profile = self.swype_mvp_normalization_profile,
        }
    end

    -- Words completing a tapped-out word: prefix is its letters as a
    -- signature, typed the word as typed, lowercased.
    function VirtualKeyboard:_swypeCompleteWord(prefix, typed, previous_word,
            limit)
        return adapter.recognition_engine:completeWord{
            prefix = prefix,
            typed = typed,
            limit = limit,
            dictionary = self.swype_mvp_dictionary or "en",
            normalization_profile = self.swype_mvp_normalization_profile,
            previous_word = previous_word,
            context_bonus = function(previous, word)
                return self:_swypeContextBonus(previous, word)
            end,
            word_uses = function(word)
                return self:_swypeWordUses(word)
            end,
            full = true,
            only_loaded = true,
        }
    end

    function VirtualKeyboard:_swypeGetPreviousWord()
        return adapter.input_controller:getPreviousWord(self)
    end

    function VirtualKeyboard:_swypeContextBonus(previous_word, word)
        return adapter.input_controller:contextBonus(previous_word, word,
            self.swype_mvp_dictionary or "en")
    end

    function VirtualKeyboard:_swypeWordUses(word)
        return adapter.input_controller:wordUses(word)
    end

    function VirtualKeyboard:_swypeCommitPendingContext()
        adapter.input_controller:commitPendingContext(self)
    end

    function VirtualKeyboard:_swypeSaveContext()
        adapter.input_controller:saveContext()
    end

    function VirtualKeyboard:_swypeDictionaryLabel()
        return adapter.dictionary_controller:label(self)
    end

    function VirtualKeyboard:_swypeToggleDictionary()
        return adapter.dictionary_controller:toggle(self)
    end

    function VirtualKeyboard:_swypeSetDictionary(dictionary)
        return adapter.dictionary_controller:setDictionary(self, dictionary)
    end

    function VirtualKeyboard:_swypeRefreshCandidateRow(refresh_type, only_index)
        adapter.keyboard_ui:refreshCandidateRow(
            self, refresh_type, only_index)
    end

    function VirtualKeyboard:_swypeRefreshLanguageIndicator(refresh_type)
        adapter.keyboard_ui:refreshLanguageIndicator(self, refresh_type)
    end


    function VirtualKeyboard:_swypeClearCandidateState(keep_debug)
        adapter.input_controller:clearCandidateState(self, keep_debug)
    end

    function VirtualKeyboard:_swypeClearCandidateRow(refresh_type)
        adapter.input_controller:clearCandidateRow(self, refresh_type)
    end

    function VirtualKeyboard:_swypeSelectCandidate(candidate)
        adapter.input_controller:selectCandidate(self, candidate)
    end

    function VirtualKeyboard:_swypeBlockCandidate(candidate)
        return adapter.input_controller:blockCandidate(self, candidate)
    end

    function VirtualKeyboard:_swypeAddPersonalWord()
        return adapter.input_controller:addPersonalWord(self)
    end

    function VirtualKeyboard:_swypeFinalizeSignature(signature, trace_info)
        return adapter.input_controller:finalizeSignature(
            self, signature, trace_info)
    end

    function VirtualKeyboard:onSwypeWordPan(_, ges)
        return adapter.gesture_controller:onPan(self, ges)
    end

    function VirtualKeyboard:_onSwypeWordPathRelease(_, ges, source_key)
        return adapter.gesture_controller:onPathRelease(
            self, ges, source_key)
    end

    function VirtualKeyboard:onSwypeWordSwipe(_, ges, source_key)
        return self:_onSwypeWordPathRelease(_, ges, source_key)
    end

    function VirtualKeyboard:onSwypeWordMultiswipe(_, ges, source_key)
        return self:_onSwypeWordPathRelease(_, ges, source_key)
    end

    function VirtualKeyboard:onSwypeWordPanRelease(_, ges)
        return adapter.gesture_controller:onPanRelease(self, ges)
    end

    -- Catches the hold_release a hold always ends with, however far the
    -- lift lands from the globe key. A key's own onHoldReleaseKey still
    -- gets first refusal when the lift lands on it.
    function VirtualKeyboard:onSwypeHoldRelease(_, ges)
        return self:_swypeTakeLift()
    end

    function VirtualKeyboard:addChar(key, keep_swype_candidates)
        adapter.input_controller:addChar(
            self, key, keep_swype_candidates)
    end

    function VirtualKeyboard:delChar()
        adapter.input_controller:delChar(self)
    end

    return VirtualKeyboard
end

return KoreaderAdapter
