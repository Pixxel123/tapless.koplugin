local TraceRenderer = {}
TraceRenderer.__index = TraceRenderer

function TraceRenderer:new(screen, ui_manager, geometry)
    return setmetatable({
        screen = assert(screen),
        ui_manager = assert(ui_manager),
        geometry = assert(geometry),
    }, self)
end

function TraceRenderer:invertPixelSet(pixel_set)
    local min_x, min_y = math.huge, math.huge
    local max_x, max_y = -math.huge, -math.huge
    for y, row in pairs(pixel_set or {}) do
        local run_start
        local previous_x
        local xs = {}
        for x in pairs(row) do
            table.insert(xs, x)
        end
        table.sort(xs)
        for _, current_x in ipairs(xs) do
            min_x = math.min(min_x, current_x)
            min_y = math.min(min_y, y)
            max_x = math.max(max_x, current_x)
            max_y = math.max(max_y, y)
            if not run_start then
                run_start = current_x
            elseif current_x ~= previous_x + 1 then
                self.screen.bb:invertRect(
                    run_start, y, previous_x - run_start + 1, 1)
                run_start = current_x
            end
            previous_x = current_x
        end
        if run_start then
            self.screen.bb:invertRect(
                run_start, y, previous_x - run_start + 1, 1)
        end
    end
    if min_x == math.huge then
        return
    end
    return self.geometry:new{
        x = min_x,
        y = min_y,
        w = max_x - min_x + 1,
        h = max_y - min_y + 1,
    }
end

function TraceRenderer:drawSegment(trace, previous, current)
    if not trace or not current then
        return
    end
    trace.drawn_pixels = trace.drawn_pixels or {}
    local new_pixels = {}
    local radius = 1
    local start_x = previous and previous.x or current.x
    local start_y = previous and previous.y or current.y
    local dx = current.x - start_x
    local dy = current.y - start_y
    local steps = math.max(math.abs(dx), math.abs(dy))
    if steps < 1 then
        steps = 1
    end
    for step = 0, steps do
        local center_x = math.floor(start_x + dx * step / steps + 0.5)
        local center_y = math.floor(start_y + dy * step / steps + 0.5)
        for offset_y = -radius, radius do
            local y = center_y + offset_y
            local row = trace.drawn_pixels[y]
            if not row then
                row = {}
                trace.drawn_pixels[y] = row
            end
            local new_row = new_pixels[y]
            if not new_row then
                new_row = {}
                new_pixels[y] = new_row
            end
            for offset_x = -radius, radius do
                local x = center_x + offset_x
                if not row[x] then
                    row[x] = true
                    new_row[x] = true
                end
            end
        end
    end
    local region = self:invertPixelSet(new_pixels)
    if region then
        self.ui_manager:setDirty(nil, "a2", region)
    end
end

function TraceRenderer:clear(trace, refresh_type)
    if not trace or not trace.drawn_pixels then
        return
    end
    local region = self:invertPixelSet(trace.drawn_pixels)
    trace.drawn_pixels = nil
    if region then
        self.ui_manager:setDirty(nil, refresh_type or "ui", region)
    end
end

return TraceRenderer
