local PrefetchController = {}
PrefetchController.__index = PrefetchController

function PrefetchController:new(dictionary_store, ui_manager, is_trace_active,
        batch_size, work_ms)
    return setmetatable({
        dictionary_store = assert(dictionary_store),
        ui_manager = assert(ui_manager),
        is_trace_active = assert(is_trace_active),
        batch_size = batch_size or 96,
        work_ms = work_ms or 3,
        generation = 0,
        controller = nil,
    }, self)
end

function PrefetchController:cancel()
    self.generation = self.generation + 1
    local controller = self.controller
    if not controller then
        return
    end
    self.dictionary_store:discardPrefetch(controller)
    self.controller = nil
end

function PrefetchController:schedule(trace, dictionary, priority_lasts)
    if not trace or #trace.letters < 2 then
        return
    end
    dictionary = dictionary or "en"
    local first = trace.letters[1]
    local controller = self.controller
    if not controller or controller.dictionary ~= dictionary
            or controller.first ~= first then
        self:cancel()
        controller = {
            dictionary = dictionary,
            first = first,
            current_last = trace.letters[#trace.letters],
            priority_lasts = priority_lasts,
            jobs = {},
        }
        self.controller = controller
        self.generation = self.generation + 1
        controller.generation = self.generation
    else
        controller.current_last = trace.letters[#trace.letters]
        controller.priority_lasts = priority_lasts
    end
    if controller.scheduled then
        return
    end

    local function scheduleStep(delay)
        controller.scheduled = true
        self.ui_manager:scheduleIn(delay, function()
            controller.scheduled = false
            if self.controller ~= controller
                    or self.generation ~= controller.generation
                    or not self.is_trace_active() then
                return
            end

            local selected_job
            local selected_key
            local function select_last(last)
                if not last then
                    return
                end
                local key = controller.first .. last
                local job = controller.jobs[key]
                if not self.dictionary_store:isBucketLoaded(
                        controller.dictionary, key)
                        and (not job or not job.completed) then
                    selected_key = key
                    selected_job = job
                end
            end
            for _, last in ipairs(controller.priority_lasts or {}) do
                select_last(last)
                if selected_key then
                    break
                end
            end
            if not selected_key then
                select_last(controller.current_last)
            end
            if not selected_key then
                for code = string.byte("a"), string.byte("z") do
                    select_last(string.char(code))
                    if selected_key then
                        break
                    end
                end
            end

            if not selected_job and selected_key then
                selected_job = self.dictionary_store:startPrefetch(
                    controller.first, string.sub(selected_key, 2, 2),
                    controller.dictionary)
                if selected_job then
                    controller.jobs[selected_key] = selected_job
                end
            end
            if selected_job and not selected_job.completed
                    and not selected_job.cancelled then
                self.dictionary_store:advancePrefetch(
                    selected_job, self.batch_size, self.work_ms)
            end

            local unfinished = false
                for code = string.byte("a"), string.byte("z") do
                local key = controller.first .. string.char(code)
                if not self.dictionary_store:isBucketLoaded(
                        controller.dictionary, key) then
                    unfinished = true
                    break
                end
            end
            if unfinished then
                scheduleStep(0.01)
            end
        end)
    end
    scheduleStep(0.06)
end

return PrefetchController
