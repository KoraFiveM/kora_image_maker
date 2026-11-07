local APP_ID = 'kora_image_maker:tool'
local Room = ImageMaker.room
local Capture = ImageMaker.capture

local HISTORY_LIMIT = 30
local MAX_MODELS = 60
local STOP_CONTROL = 73 -- X

-- Webhook and auto-post live in this player's local KVP, so the field is
-- pre-filled every time the panel opens, across restarts and relogs.
local settings = {
    webhook = GetResourceKvpString('webhook') or '',
    autopost = GetResourceKvpInt('autopost') == 1,
}

local history = {}
local opening = false
local pendingScene -- scene clip queued by an action that closed the panel
local appDefinition

local ANGLE_LABELS = {
    default = 'Default (library)',
    front = 'Front',
    three_quarter_front = 'Front 3/4',
    side = 'Side',
    three_quarter_rear = 'Rear 3/4',
    rear = 'Rear',
    top = 'Top down',
    portrait = 'Ped headshot',
}

local VEHICLE_COLOURS = {
    { value = 'keep', label = 'Model default' },
    { value = '0', label = 'Black' },
    { value = '111', label = 'White' },
    { value = '4', label = 'Silver' },
    { value = '27', label = 'Red' },
    { value = '64', label = 'Blue' },
    { value = '89', label = 'Yellow' },
    { value = '92', label = 'Lime' },
}

local function notify(message, kind)
    Kora.notify.send({ title = 'Image Maker', message = message, type = kind or 'info' })
end

local function notice(tone, message)
    return { notice = { tone = tone, message = message } }
end

local function isWebhook(url)
    return type(url) == 'string'
        and url:match('^https://[%w%.]*discord[%w]*%.com/api/webhooks/%d+/[%w_%-]+') ~= nil
end

local function saveWebhook(url)
    if type(url) ~= 'string' then return end
    url = url:gsub('^%s+', ''):gsub('%s+$', '')
    if url == settings.webhook then return end
    settings.webhook = url
    SetResourceKvp('webhook', url)
end

local function saveAutopost(on)
    if type(on) ~= 'boolean' then return end
    settings.autopost = on
    SetResourceKvpInt('autopost', on and 1 or 0)
end

---@return table|nil discord, string? error
local function discordTarget(wanted, content)
    if not wanted then return nil end
    if not isWebhook(settings.webhook) then return nil, 'Set a Discord webhook in the Discord tab first.' end
    return { url = settings.webhook, content = content }
end

local function fmtBytes(n)
    if type(n) ~= 'number' then return '?' end
    if n >= 1048576 then return ('%.1f MB'):format(n / 1048576) end
    return ('%d KB'):format(math.floor(n / 1024 + 0.5))
end

local function addHistory(entry)
    table.insert(history, 1, entry)
    while #history > HISTORY_LIMIT do table.remove(history) end
end

local savedPaths = {} -- history id -> server-relative path, for re-posting

local function recordResult(label, kind, captureId, result)
    if result.ok and result.path then savedPaths[captureId] = result.path end
    local parts = {}
    if result.ok then
        parts[#parts + 1] = result.path or 'saved'
        if result.width then parts[#parts + 1] = ('%dx%d'):format(result.width, result.height) end
        parts[#parts + 1] = fmtBytes(result.bytes)
    else
        parts[#parts + 1] = result.error or 'failed'
    end
    if result.discord then
        parts[#parts + 1] = result.discord.ok and 'posted to Discord' or ('Discord: ' .. (result.discord.error or 'failed'))
    end
    addHistory({
        id = captureId,
        label = label,
        description = table.concat(parts, ' · '),
        badge = kind,
        tone = result.ok and ((result.discord and not result.discord.ok) and 'warning' or 'success') or 'destructive',
        actions = result.ok and { { id = 'repost', label = 'Post to Discord', icon = 'MessageSquare', variant = 'outline' } } or nil,
    })
end

local function parseModels(text)
    local models, seen = {}, {}
    if type(text) ~= 'string' then return models end
    for model in text:gmatch('[^%s,;]+') do
        model = model:lower()
        if model:match('^[%w_%-]+$') and not seen[model] then
            seen[model] = true
            models[#models + 1] = model
            if #models >= MAX_MODELS then break end
        end
    end
    return models
end

local function clampNumber(value, min, max, fallback)
    value = tonumber(value)
    if not value then return fallback end
    return math.max(min, math.min(max, value))
end

local function refresh(result)
    result = result or {}
    result.update = { navigation = appDefinition().navigation }
    return result
end

-- ------------------------------------------------------------- green room

local function captureEntityPhotos(value)
    local models = parseModels(value.models)
    if #models == 0 then return notice('destructive', 'Enter at least one model name.') end
    local angles = type(value.angles) == 'table' and value.angles or {}
    if #angles == 0 then angles = { 'default' } end
    local discord, derr = discordTarget(value.discord == true, nil)
    if derr then return notice('destructive', derr) end

    local ok, err = Room.enter()
    if not ok then return notice('destructive', err) end

    local zoom = clampNumber(value.zoom, 0.2, 5.0, 1.0)
    local colour = value.colour ~= 'keep' and tonumber(value.colour) or nil
    local background = value.background or 'transparent'
    local maxSize = tonumber(value.size) or 0

    local done, failed = 0, {}
    for _, model in ipairs(models) do
        local entity, typeOrErr = Room.spawn(model, { colour = colour })
        if not entity then
            failed[#failed + 1] = typeOrErr
        else
            for _, angle in ipairs(angles) do
                if ANGLE_LABELS[angle] then
                    Room.aimPreset(angle, zoom)
                    Wait(150)
                    local target = discord and { url = discord.url, content = ('**%s** · %s · %s'):format(model, typeOrErr, ANGLE_LABELS[angle]) }
                    local result = Capture.photo(
                        { kind = 'entity', type = typeOrErr, model = model, angle = angle },
                        { key = true, background = background, crop = true, maxSize = maxSize, format = 'png' },
                        target)
                    local captureId = ('photo_%s_%s_%d'):format(model, angle, GetGameTimer())
                    result.captureId = captureId
                    recordResult(('%s (%s)'):format(model, ANGLE_LABELS[angle]), typeOrErr, captureId, result)
                    if result.ok then done = done + 1 else failed[#failed + 1] = ('%s/%s: %s'):format(model, angle, result.error) end
                end
            end
        end
    end

    local total = done + #failed
    if done == 0 then return refresh(notice('destructive', failed[1] or 'Nothing captured.')) end
    local message = ('Captured %d/%d.'):format(done, total)
    if #failed > 0 then message = message .. ' First failure: ' .. failed[1] end
    return refresh(notice(#failed > 0 and 'warning' or 'success', message))
end

local function recordEntityVideo(value)
    local discord, derr = discordTarget(value.discord == true, nil)
    if derr then return notice('destructive', derr) end

    local model = parseModels(value.model)[1]
    local entity, _, entityType = Room.current()
    if model then
        local ok, err = Room.enter()
        if not ok then return notice('destructive', err) end
        local spawned, typeOrErr = Room.spawn(model, { colour = value.colour ~= 'keep' and tonumber(value.colour) or nil })
        if not spawned then return notice('destructive', typeOrErr) end
        entity, entityType = spawned, typeOrErr
    elseif not entity then
        return notice('destructive', 'Enter a model, or capture a photo first so something is in the green room.')
    end
    local _, currentModel = Room.current()
    model = currentModel

    local seconds = clampNumber(value.seconds, 2, 30, 8)
    local zoom = clampNumber(value.zoom, 0.2, 5.0, 1.0)
    local pitch = tonumber(value.height) or 12
    local motion = value.motion == 'details' and 'details' or 'orbit'

    -- Detail fly-around needs vehicle bones; anything else falls back to orbit.
    local plan, fellBack
    if motion == 'details' then
        plan = Room.planBoneTour(seconds, pitch, zoom)
        if not plan then motion, fellBack = 'orbit', true end
    end

    Room.setEntityHeading(0.0)
    if plan then Room.tourAt(plan, 0.0) else Room.aim(-40, pitch, zoom) end
    Wait(150)

    local job, err = Capture.startVideo({ kind = 'video', model = model, motion = motion }, {
        key = value.background ~= 'green',
        background = value.background or 'black',
        height = tonumber(value.quality) or 1080,
        fps = 30,
        seconds = seconds,
        discord = discord ~= nil,
    })
    if not job then
        Room.setFov()
        return notice('destructive', err)
    end

    local startedAt = GetGameTimer()
    local duration = seconds * 1000
    while true do
        local t = (GetGameTimer() - startedAt) / duration
        if t >= 1.0 then break end
        if plan then Room.tourAt(plan, t) else Room.aim(-40 + t * 360.0, pitch, zoom) end
        Wait(0)
    end
    Room.setFov()

    local target = discord and { url = discord.url, content = ('**%s** · %s · %ds %s'):format(model, entityType, seconds, motion) }
    local result = Capture.stopVideo(job, target)
    local captureId = ('video_%s_%d'):format(model, GetGameTimer())
    recordResult(('%s %s video'):format(model, motion), 'video', captureId, result)
    if not result.ok then return refresh(notice('destructive', result.error or 'Recording failed.')) end
    local message = ('Saved %s (%s).'):format(result.path, fmtBytes(result.bytes))
    if fellBack then message = message .. ' Detail fly-around is vehicles only, so it orbited instead.' end
    if result.discord and not result.discord.ok then return refresh(notice('warning', message .. ' Discord: ' .. result.discord.error)) end
    return refresh(notice(fellBack and 'warning' or 'success', message))
end

-- ------------------------------------------------------------------ scene

local function sceneDiscordContent(kind)
    local name = GetPlayerName(PlayerId()) or 'admin'
    return ('%s from %s'):format(kind, name)
end

local function takeScenePhoto(value)
    local discord, derr = discordTarget(value.discord == true, sceneDiscordContent('Screenshot'))
    if derr then return notice('destructive', derr) end
    Room.leave()

    local hideHud = value.hideHud ~= false
    local hiding = hideHud
    if hiding then
        CreateThread(function()
            while hiding do HideHudAndRadarThisFrame() Wait(0) end
        end)
        Wait(100)
    end
    local format = value.format == 'png' and 'png' or 'jpg'
    local result = Capture.photo({ kind = 'scene' }, { key = false, format = format, quality = 0.92 }, discord)
    hiding = false

    local captureId = ('scene_%d'):format(GetGameTimer())
    recordResult('Screenshot', 'photo', captureId, result)
    if not result.ok then return refresh(notice('destructive', result.error or 'Screenshot failed.')) end
    return refresh(notice('success', ('Saved %s (%s).'):format(result.path, fmtBytes(result.bytes))))
end

-- Runs with the panel closed so the player can move; X stops early.
local function recordSceneClip(value)
    local discord = discordTarget(value.discord == true, sceneDiscordContent('Clip'))
    local seconds = clampNumber(value.seconds, 2, 120, 15)
    local hideHud = value.hideHud ~= false

    local job, err = Capture.startVideo({ kind = 'video', motion = 'clip' }, {
        key = false,
        height = tonumber(value.quality) or 1080,
        fps = 30,
        seconds = seconds,
        discord = discord ~= nil,
        hint = 'press X to stop',
    })
    if not job then return notify(err, 'error') end

    local deadline = GetGameTimer() + seconds * 1000
    while GetGameTimer() < deadline do
        if hideHud then HideHudAndRadarThisFrame() end
        DisableControlAction(0, STOP_CONTROL, true)
        if IsDisabledControlJustPressed(0, STOP_CONTROL) then break end
        Wait(0)
    end

    notify('Saving clip...', 'info')
    local result = Capture.stopVideo(job, discord)
    local captureId = ('clip_%d'):format(GetGameTimer())
    recordResult('Gameplay clip', 'video', captureId, result)
    if not result.ok then return notify(result.error or 'Recording failed.', 'error') end
    local message = ('Saved %s (%s).'):format(result.path, fmtBytes(result.bytes))
    if result.discord then
        message = message .. (result.discord.ok and ' Posted to Discord.' or (' Discord: ' .. result.discord.error))
    end
    notify(message, (result.discord and not result.discord.ok) and 'warning' or 'success')
end

-- ---------------------------------------------------------------- actions

local function handleAction(actionId, context)
    local value = type(context.value) == 'table' and context.value or {}

    if actionId == 'photo' then
        return captureEntityPhotos(value)
    elseif actionId == 'video' then
        return recordEntityVideo(value)
    elseif actionId == 'leave' then
        Room.leave()
        return notice('success', 'Left the green room.')
    elseif actionId == 'scene-photo' then
        return takeScenePhoto(value)
    elseif actionId == 'scene-video' then
        if value.discord == true and not isWebhook(settings.webhook) then
            return notice('destructive', 'Set a Discord webhook in the Discord tab first.')
        end
        Room.leave()
        pendingScene = value
        return { close = true }
    elseif actionId == 'discord-save' then
        if value.webhook ~= nil and value.webhook ~= '' and not isWebhook(value.webhook) then
            return notice('destructive', 'That is not a Discord webhook URL.')
        end
        saveWebhook(value.webhook or '')
        saveAutopost(value.autopost == true)
        return refresh(notice('success', settings.webhook == '' and 'Webhook cleared.' or 'Saved on this PC.'))
    elseif actionId == 'discord-test' then
        if not isWebhook(settings.webhook) then return notice('destructive', 'Save a webhook URL first.') end
        local result = Capture.testWebhook(settings.webhook,
            ('Kora Image Maker connected (%s).'):format(GetPlayerName(PlayerId()) or 'admin'))
        if result.ok then return notice('success', 'Test message posted.') end
        return notice('destructive', result.error or 'Discord rejected the message.')
    elseif actionId == 'repost' then
        local discord, derr = discordTarget(true, nil)
        if derr then return notice('destructive', derr) end
        local entry
        for _, item in ipairs(history) do if item.id == context.itemId then entry = item break end end
        if not entry or not savedPaths[entry.id] then return notice('destructive', 'Capture not found.') end
        discord.content = ('**%s**'):format(entry.label)
        local result = Capture.repost(savedPaths[entry.id], discord)
        if result.ok then return notice('success', 'Posted to Discord.') end
        return notice('destructive', result.error or 'Discord post failed.')
    end
end

-- Remember the webhook as it's typed, not just on save.
local function handleChange(actionId, context)
    if actionId ~= 'discord-save' then return end
    local value = type(context.value) == 'table' and context.value or {}
    if isWebhook(value.webhook) then saveWebhook(value.webhook) end
end

-- ------------------------------------------------------------- definition

local function angleOptions()
    local options = {}
    for _, id in ipairs(Room.angleIds) do options[#options + 1] = { value = id, label = ANGLE_LABELS[id] } end
    return options
end

local function discordField()
    return {
        id = 'discord', label = 'Post to Discord', type = 'checkbox', default = settings.autopost,
        description = isWebhook(settings.webhook) and nil or 'Set a webhook in the Discord tab first.',
    }
end

local function qualityField()
    return {
        id = 'quality', label = 'Resolution', type = 'select', default = '1080',
        options = { { value = '720', label = '720p' }, { value = '1080', label = '1080p' }, { value = '0', label = 'Native' } },
    }
end

local function currentStats()
    local entity, model, entityType = Room.current()
    return {
        type = 'stats',
        items = {
            { label = 'Green room', value = Room.isActive() and 'Active' or 'Off', icon = 'Box', tone = Room.isActive() and 'success' or 'neutral' },
            { label = 'Current model', value = entity and model or 'None', description = entityType, icon = 'Car' },
            { label = 'Discord', value = isWebhook(settings.webhook) and 'Ready' or 'Not set', icon = 'MessageSquare', tone = isWebhook(settings.webhook) and 'success' or 'warning' },
        },
    }
end

local function historyBlock()
    if #history == 0 then
        return { type = 'empty', title = 'Nothing captured yet', description = 'Photos and videos from this session show up here.', icon = 'Camera' }
    end
    return { type = 'list', id = 'history', title = 'This session', layout = 'list', items = history }
end

appDefinition = function()
    return {
        id = APP_ID,
        title = 'Image Maker',
        description = 'Photos and videos, saved to the server',
        icon = 'Camera',
        placement = 'left',
        draggable = true,
        rememberPosition = true,
        defaultView = 'room',
        navigation = {
            {
                id = 'room',
                label = 'Green room',
                icon = 'Box',
                content = {
                    title = 'Green room',
                    description = 'Spawns models on a green screen. Photos have the green removed and are saved to images/<type>/.',
                    blocks = {
                        currentStats(),
                        {
                            type = 'actions',
                            title = 'Capture',
                            actions = {
                                {
                                    id = 'photo', label = 'Take photos', icon = 'Camera', variant = 'primary', submitLabel = 'Capture',
                                    fields = {
                                        { id = 'models', label = 'Model(s)', type = 'textarea', rows = 2, required = true,
                                          placeholder = 'adder, zentorno, a_m_y_hipster_01, prop_bench_01a',
                                          description = 'Comma or space separated. Ped, vehicle or object is detected.' },
                                        { id = 'angles', label = 'Angles', type = 'multiselect', required = true, default = { 'default' }, options = angleOptions() },
                                        { id = 'background', label = 'Background', type = 'select', default = 'transparent', options = {
                                            { value = 'transparent', label = 'Transparent' }, { value = 'black', label = 'Black' },
                                            { value = 'white', label = 'White' }, { value = 'green', label = 'Green (no keying)' },
                                        } },
                                        { id = 'size', label = 'Max size', type = 'select', default = '0', options = {
                                            { value = '0', label = 'Full (cropped)' }, { value = '1024', label = '1024 px' },
                                            { value = '512', label = '512 px' }, { value = '256', label = '256 px' },
                                        } },
                                        { id = 'colour', label = 'Vehicle colour', type = 'select', default = '0', options = VEHICLE_COLOURS },
                                        { id = 'zoom', label = 'Zoom', type = 'number', default = 1, min = 0.2, max = 5, step = 0.1 },
                                        discordField(),
                                    },
                                },
                                {
                                    id = 'video', label = 'Record fly-around video', icon = 'CircleDot', variant = 'secondary', submitLabel = 'Record',
                                    fields = {
                                        { id = 'model', label = 'Model', type = 'text', placeholder = 'Blank = current model' },
                                        { id = 'motion', label = 'Motion', type = 'select', default = 'orbit', options = {
                                            { value = 'orbit', label = 'Camera orbits' },
                                            { value = 'details', label = 'Fly around details (vehicles)' },
                                        } },
                                        { id = 'seconds', label = 'Length (seconds)', type = 'number', default = 8, min = 2, max = 30, wholeNumber = true,
                                          description = 'Detail fly-around spends about 1.3 s per detail; 15-20 s shows them all.' },
                                        { id = 'height', label = 'Camera height', type = 'select', default = '12', options = {
                                            { value = '4', label = 'Low' }, { value = '12', label = 'Mid' }, { value = '30', label = 'High' },
                                        } },
                                        { id = 'background', label = 'Background', type = 'select', default = 'black', options = {
                                            { value = 'black', label = 'Black' }, { value = 'white', label = 'White' }, { value = 'green', label = 'Green screen' },
                                        } },
                                        { id = 'colour', label = 'Vehicle colour', type = 'select', default = '0', options = VEHICLE_COLOURS },
                                        { id = 'zoom', label = 'Zoom', type = 'number', default = 1, min = 0.2, max = 5, step = 0.1 },
                                        qualityField(),
                                        discordField(),
                                    },
                                },
                                { id = 'leave', label = 'Leave green room', icon = 'DoorOpen', variant = 'outline' },
                            },
                        },
                    },
                },
            },
            {
                id = 'scene',
                label = 'Screen',
                icon = 'PanelsTopLeft',
                content = {
                    title = 'Your view',
                    description = 'Capture what you see in-game. The panel and other UI are never in the shot. Saved to captures/.',
                    blocks = {
                        {
                            type = 'actions',
                            actions = {
                                {
                                    id = 'scene-photo', label = 'Screenshot', icon = 'Camera', variant = 'primary', submitLabel = 'Take screenshot',
                                    fields = {
                                        { id = 'format', label = 'Format', type = 'select', default = 'jpg', options = {
                                            { value = 'jpg', label = 'JPEG (smaller)' }, { value = 'png', label = 'PNG (lossless)' },
                                        } },
                                        { id = 'hideHud', label = 'Hide HUD', type = 'checkbox', default = true },
                                        discordField(),
                                    },
                                },
                                {
                                    id = 'scene-video', label = 'Record clip', icon = 'CircleDot', variant = 'secondary', submitLabel = 'Start recording',
                                    fields = {
                                        { id = 'seconds', label = 'Max length (seconds)', type = 'number', default = 15, min = 2, max = 120, wholeNumber = true,
                                          description = 'The panel closes while recording. Press X to stop early.' },
                                        qualityField(),
                                        { id = 'hideHud', label = 'Hide HUD', type = 'checkbox', default = true },
                                        discordField(),
                                    },
                                },
                            },
                        },
                    },
                },
            },
            {
                id = 'history',
                label = 'History',
                icon = 'Clock',
                content = {
                    title = 'Captures',
                    description = 'Anything saved this session can be re-posted to Discord.',
                    blocks = { historyBlock() },
                },
            },
            {
                id = 'discord',
                label = 'Discord',
                icon = 'MessageSquare',
                content = {
                    title = 'Discord webhook',
                    description = 'Stored on this PC only, so it is filled in next time. Discord caps uploads at 10 MB; videos are encoded to fit when posting.',
                    blocks = {
                        {
                            type = 'form',
                            id = 'discord-form',
                            action = { id = 'discord-save', label = 'Save' },
                            submitLabel = 'Save',
                            fields = {
                                { id = 'webhook', label = 'Webhook URL', type = 'text', default = settings.webhook,
                                  placeholder = 'https://discord.com/api/webhooks/...' },
                                { id = 'autopost', label = 'Tick "Post to Discord" by default', type = 'checkbox', default = settings.autopost },
                            },
                        },
                        { type = 'actions', actions = { { id = 'discord-test', label = 'Send test message', icon = 'MessageSquare', variant = 'outline' } } },
                    },
                },
            },
        },
        onAction = handleAction,
        onChange = handleChange,
    }
end

local function open()
    if opening then return end
    opening = true
    Kora.nui.registerApp(appDefinition())
    local viewId = 'room'
    while true do
        Kora.nui.openApp(APP_ID, { viewId = viewId })
        if not pendingScene then break end
        local value = pendingScene
        pendingScene = nil
        local ok, err = pcall(recordSceneClip, value)
        if not ok then notify('Recording failed: ' .. tostring(err), 'error') end
        Kora.nui.updateApp(APP_ID, { navigation = appDefinition().navigation })
        viewId = 'scene'
    end
    -- openApp returns on any close (X, Escape, resource stop): never leave the
    -- player frozen and invisible in the green room.
    Room.leave()
    opening = false
end

RegisterNetEvent('kora_image_maker:client:open', function()
    if source ~= 65535 then return end
    CreateThread(open)
end)
