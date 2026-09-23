local DictionaryController = {}
DictionaryController.__index = DictionaryController

function DictionaryController:new(options)
    return setmetatable({
        plugin_dir = assert(options.plugin_dir),
        manager = assert(options.manager),
        registry = assert(options.registry),
        store = assert(options.store),
        scoring = assert(options.scoring),
        ui_manager = assert(options.ui_manager),
        settings = assert(options.settings),
        logger = assert(options.logger),
        setting_key = assert(options.setting_key),
        enabled_setting_key = assert(options.enabled_setting_key),
        setup_setting_key = assert(options.setup_setting_key),
        default_profile = assert(options.default_profile),
    }, self)
end

function DictionaryController:_installed()
    return self.manager:listInstalled(self.plugin_dir)
end

function DictionaryController:listEnabled()
    local installed = self:_installed()
    local configured = self.settings:readSetting(self.enabled_setting_key)

    -- Existing users start with all installed dictionaries enabled.
    if type(configured) ~= "table" then
        return installed
    end

    local wanted = {}
    for _, id in ipairs(configured) do
        if type(id) == "string" then
            wanted[id] = true
        end
    end

    local enabled = {}
    for _, info in ipairs(installed) do
        if wanted[info.id] then
            table.insert(enabled, info)
        end
    end

    -- Recover safely if settings refer only to dictionaries that no longer
    -- exist. The manager still prevents deliberately disabling the last one.
    if #enabled == 0 and #installed > 0 then
        table.insert(enabled, installed[1])
        self.settings:saveSetting(
            self.enabled_setting_key, { installed[1].id })
    end

    return enabled
end

function DictionaryController:isEnabled(id)
    for _, info in ipairs(self:listEnabled()) do
        if info.id == id then
            return true
        end
    end
    return false
end

function DictionaryController:activeDictionary(keyboard)
    return keyboard and keyboard.swype_mvp_dictionary
        or self.settings:readSetting(self.setting_key, "en")
end

-- The language whose personal words to show, and its normalization
-- profile: the keyboard's when one is open, otherwise the saved language.
function DictionaryController:personalContext(keyboard)
    local dictionary = self:activeDictionary(keyboard)
    local profile = keyboard and keyboard.swype_mvp_normalization_profile
    if not profile then
        local descriptor = self.registry:get(dictionary, self.plugin_dir)
        profile = descriptor and descriptor.normalization_profile
            or self.default_profile
    end
    return dictionary, profile
end

function DictionaryController:setEnabled(id, enabled, keyboard)
    if not self.manager:isDictionaryAvailable(id, self.plugin_dir) then
        return false, "Dictionary is not installed."
    end

    local current = {}
    for _, info in ipairs(self:listEnabled()) do
        current[info.id] = true
    end

    if enabled then
        current[id] = true
    else
        current[id] = nil
    end

    local result = {}
    for _, info in ipairs(self:_installed()) do
        if current[info.id] then
            table.insert(result, info.id)
        end
    end

    if #result == 0 then
        return false, "At least one dictionary must remain enabled."
    end

    self.settings:saveSetting(self.enabled_setting_key, result)

    if not enabled and self:activeDictionary(keyboard) == id then
        if keyboard then
            if not self:setDictionary(keyboard, result[1]) then
                return false, "Cannot switch to another dictionary."
            end
        else
            self.settings:saveSetting(self.setting_key, result[1])
        end
    end

    return true
end

function DictionaryController:selectDictionary(id, keyboard)
    if not self.manager:isDictionaryAvailable(id, self.plugin_dir) then
        return false
    end

    if not self:isEnabled(id) then
        local ok = self:setEnabled(id, true, keyboard)
        if not ok then
            return false
        end
    end

    if keyboard then
        return self:setDictionary(keyboard, id)
    end

    self.settings:saveSetting(self.setting_key, id)
    return true
end

function DictionaryController:prepareRemoval(id, replacement, keyboard)
    if self:activeDictionary(keyboard) ~= id then
        return true
    end

    local target
    for _, info in ipairs(self:listEnabled()) do
        if info.id ~= id then
            target = info.id
            break
        end
    end

    if not target then
        local enabled = self:setEnabled(replacement, true, keyboard)
        if not enabled then
            return false
        end
        target = replacement
    end

    if keyboard then
        return self:setDictionary(keyboard, target)
    end

    self.settings:saveSetting(self.setting_key, target)
    return true
end

function DictionaryController:onDictionaryRemoved(id)
    local enabled_ids = {}
    for _, info in ipairs(self:listEnabled()) do
        if info.id ~= id then
            table.insert(enabled_ids, info.id)
        end
    end

    local installed = self:_installed()
    if #enabled_ids == 0 and #installed > 0 then
        enabled_ids[1] = installed[1].id
    end

    self.settings:saveSetting(self.enabled_setting_key, enabled_ids)

    local active = self.settings:readSetting(self.setting_key, "en")
    local active_enabled = false
    for _, id in ipairs(enabled_ids) do
        if id == active then
            active_enabled = true
            break
        end
    end

    if not active_enabled and enabled_ids[1] then
        self.settings:saveSetting(self.setting_key, enabled_ids[1])
    end
end

function DictionaryController:needsLanguageSetup()
    if self.settings:isTrue(self.setup_setting_key) then
        return false
    end

    local installed = self:_installed()

    -- There is nothing useful to choose when zero or one dictionary exists.
    if #installed <= 1 then
        local enabled = {}
        if installed[1] then
            enabled[1] = installed[1].id
            self.settings:saveSetting(self.setting_key, installed[1].id)
        end
        self.settings:saveSetting(self.enabled_setting_key, enabled)
        self.settings:saveSetting(self.setup_setting_key, true)
        return false
    end

    return true
end

function DictionaryController:initialLanguageSelection(keyboard)
    local selected = {}
    local configured = self.settings:readSetting(self.enabled_setting_key)

    -- Keep an existing enabled-language choice when upgrading.
    if type(configured) == "table" then
        for _, id in ipairs(configured) do
            if self.manager:isDictionaryAvailable(id, self.plugin_dir) then
                selected[id] = true
            end
        end
    end

    -- On a fresh install, start with the current dictionary only. The user
    -- can select more languages before continuing.
    if not next(selected) then
        local active = self:activeDictionary(keyboard)
        if self.manager:isDictionaryAvailable(active, self.plugin_dir) then
            selected[active] = true
        else
            local installed = self:_installed()
            if installed[1] then
                selected[installed[1].id] = true
            end
        end
    end

    return selected
end

function DictionaryController:completeLanguageSetup(selected, keyboard)
    local enabled_ids = {}

    for _, info in ipairs(self:_installed()) do
        if selected[info.id] then
            table.insert(enabled_ids, info.id)
        end
    end

    if #enabled_ids == 0 then
        return false, "Choose at least one language."
    end

    local previous = self.settings:readSetting(self.enabled_setting_key)
    self.settings:saveSetting(self.enabled_setting_key, enabled_ids)

    local active = self:activeDictionary(keyboard)
    local active_enabled = false
    for _, id in ipairs(enabled_ids) do
        if id == active then
            active_enabled = true
            break
        end
    end

    if not active_enabled then
        if keyboard then
            if not self:setDictionary(keyboard, enabled_ids[1]) then
                if previous == nil then
                    self.settings:delSetting(self.enabled_setting_key)
                else
                    self.settings:saveSetting(
                        self.enabled_setting_key, previous)
                end
                return false, "Cannot select the chosen language."
            end
        else
            self.settings:saveSetting(self.setting_key, enabled_ids[1])
        end
    end

    self.settings:saveSetting(self.setup_setting_key, true)
    return true
end

function DictionaryController:scheduleLanguageSetup(keyboard)
    if not self:needsLanguageSetup() then
        return
    end

    self.ui_manager:scheduleIn(0, function()
        if keyboard.swype_mvp_closed then
            return
        end

        local selected = self:initialLanguageSelection(keyboard)

        -- The setup dialog should replace the keyboard rather than appear
        -- behind it. Passing no keyboard also makes setup update the saved
        -- active language, which is applied when the keyboard opens again.
        keyboard:onClose()

        self.ui_manager:scheduleIn(0, function()
            self.manager:showLanguageSetup(
                nil, self.plugin_dir, selected)
        end)
    end)
end

function DictionaryController:initialize(keyboard)
    local dictionary = self.settings:readSetting(self.setting_key, "en")
    if not self.manager:isDictionaryAvailable(dictionary, self.plugin_dir)
            or not self:isEnabled(dictionary) then
        local enabled = self:listEnabled()
        dictionary = enabled[1] and enabled[1].id or "en"
        self.settings:saveSetting(self.setting_key, dictionary)
    end
    keyboard.swype_mvp_dictionary = dictionary
    local descriptor = self.registry:get(dictionary, self.plugin_dir)
    keyboard.swype_mvp_normalization_profile = descriptor
        and descriptor.normalization_profile or self.default_profile
end

function DictionaryController:label(keyboard)
    return self.manager:shortLabel(keyboard.swype_mvp_dictionary)
end

-- Switches to the next enabled language. Returns false, leaving the
-- keyboard alone, when there is no other language to switch to.
function DictionaryController:toggle(keyboard)
    local installed = self:listEnabled()
    if #installed < 2 then
        return false
    end
    keyboard:_swypeCommitPendingContext()
    local current_index
    for index, info in ipairs(installed) do
        if info.id == keyboard.swype_mvp_dictionary then
            current_index = index
            break
        end
    end
    local next_info = installed[(current_index or 0) % #installed + 1]
    keyboard:_swypeSetDictionary(next_info.id)
    return true
end

function DictionaryController:setDictionary(keyboard, dictionary)
    if not self.manager:isDictionaryAvailable(dictionary, self.plugin_dir) then
        return false
    end
    keyboard:_swypeCommitPendingContext()
    keyboard:_swypeCancelBucketPrefetch()
    self.store:invalidate(dictionary)
    keyboard.swype_mvp_dictionary = dictionary
    local descriptor = self.registry:get(dictionary, self.plugin_dir)
    keyboard.swype_mvp_normalization_profile = descriptor
        and descriptor.normalization_profile or self.default_profile
    self.store:keepOnly(dictionary)
    self.settings:saveSetting(self.setting_key, dictionary)
    self.logger.info(
        "swype mvp dictionary selected", keyboard.swype_mvp_dictionary)
    keyboard:_swypeClearCandidateRow("ui")
 keyboard:_swypeRefreshLanguageIndicator("flashui")
    keyboard:_swypeScheduleWarmUp(0.1)
    return true
end

function DictionaryController:scheduleWarmUp(keyboard, delay)
    keyboard.swype_mvp_warm_generation =
        (keyboard.swype_mvp_warm_generation or 0) + 1
    local generation = keyboard.swype_mvp_warm_generation
    local dictionary = keyboard.swype_mvp_dictionary or "en"
    self.ui_manager:scheduleIn(delay or 0.35, function()
        if keyboard.swype_mvp_warm_generation ~= generation
                or not keyboard.visible
                or keyboard.swype_mvp_dictionary ~= dictionary then
            return
        end
        if keyboard.swype_mvp_trace then
            keyboard:_swypeScheduleWarmUp(0.5)
            return
        end
        self.store:keepOnly(dictionary)
        self.store:open(dictionary)
        self.scoring:warm()
    end)
end

function DictionaryController:stopWarmUp(keyboard)
    keyboard.swype_mvp_warm_generation =
        (keyboard.swype_mvp_warm_generation or 0) + 1
end

return DictionaryController
