local APP_ID = 'kora_image_maker:tool'
local Scene = ImageMaker.scene
local Shots = ImageMaker.shots
local Env = ImageMaker.env
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

-- Last-used setup, reapplied to every model spawned (batch photos included).
local lastLocation = 'studio'
local look = { customPaint = true, paint = '#0d0d0f', tuned = false, neon = false, neonColour = '#00b3ff', plate = 'KORA', dirty = false }
local pose = { doors = {}, lights = 'off', steer = 'straight', roof = false, engine = false, interior = false }
local frame = { angle = 'hero', lens = '35', zoom = 1.0, dof = false }

local history = {}
local savedPaths = {} -- history id -> server-relative path, for re-posting
local opening = false
local pendingScene -- gameplay clip queued by an action that closed the panel
local appDefinition

local LENSES = {
    { value = '60', label = 'Ultra wide (60°)' },
    { value = '45', label = 'Wide (45°)' },
    { value = '35', label = 'Normal (35°)' },
    { value = '24', label = 'Tele (24°)' },
    { value = '15', label = 'Long tele (15°)' },
}
local ASPECTS = {
    { value = '0', label = 'Full screen' },
    { value = '1.7778', label = '16:9' },
    { value = '2.3333', label = '21:9 cinematic' },
    { value = '0.5625', label = '9:16 vertical (Shorts/TikTok)' },
    { value = '1', label = '1:1 square' },
    { value = '0.8', label = '4:5 portrait' },
}
local DOOR_OPTIONS = {
    { value = 'front', label = 'Front doors' },
    { value = 'rear', label = 'Rear doors' },
    { value = 'hood', label = 'Hood' },
    { value = 'trunk', label = 'Trunk' },
}

-- ---------------------------------------------------------------- helpers

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

local function clampNumber(value, min, max, fallback)
    value = tonumber(value)
    if not value then return fallback end
    return math.max(min, math.min(max, value))
end

local function pretty(id)
    return (id:lower():gsub('_', ' '):gsub('^%l', string.upper))
end

local function addHistory(entry)
    table.insert(history, 1, entry)
    while #history > HISTORY_LIMIT do table.remove(history) end
end

local function recordResult(label, kind, result)
    local captureId = ('cap_%d_%d'):format(GetGameTimer(), #history)
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

local function refresh(result)
    result = result or {}
    result.update = { navigation = appDefinition().navigation }
    return result
end

local function readLook(value)
    return {
        customPaint = value.customPaint ~= false,
        paint = type(value.paint) == 'string' and value.paint or look.paint,
        tuned = value.tuned == true,
        neon = value.neon == true,
        neonColour = type(value.neonColour) == 'string' and value.neonColour or look.neonColour,
        plate = type(value.plate) == 'string' and value.plate or look.plate,
        dirty = value.dirty == true,
    }
end

local function sceneLook(l)
    return {
        paint = l.customPaint and l.paint or nil,
        tuned = l.tuned,
        neon = l.neon and l.neonColour or false,
        plate = l.plate,
        dirty = l.dirty,
    }
end

local function readPose(value)
    return {
        doors = type(value.doors) == 'table' and value.doors or {},
        lights = value.lights or 'off',
        steer = value.steer or 'straight',
        roof = value.roof == true,
        engine = value.engine == true,
        interior = value.interior == true,
    }
end

local function readFrame(value)
    return {
        angle = Shots.angleLabel[value.angle] and value.angle ~= 'current' and value.angle or frame.angle,
        lens = value.lens or frame.lens,
        zoom = clampNumber(value.zoom, 0.2, 5.0, frame.zoom),
        dof = value.dof == true,
    }
end

local function applyFrame()
    Scene.setLens(frame.lens)
    Scene.setDof(frame.dof)
    local cam, target = Shots.angle(frame.angle, Scene.context(), frame.zoom)
    if cam then Scene.look(cam, target) end
end

---Spawns a model at the current (or last) location with the saved look/pose.
local function spawnSubject(model, locationId)
    locationId = locationId or (Scene.isActive() and Scene.location().id) or lastLocation
    local ok, err = Scene.enter(locationId)
    if not ok then return false, err end
    lastLocation = locationId
    if Scene.isGreen() and not Env.isCustom() then
        Env.apply({ weather = 'EXTRASUNNY', hour = 12, minute = 0 }) -- even studio light by default
    end
    local entity, typeOrErr = Scene.spawn(model)
    if not entity then return false, typeOrErr end
    Scene.style(sceneLook(look))
    Scene.pose(pose)
    applyFrame()
    return entity, typeOrErr
end

-- ------------------------------------------------------------------- shoot

local function doSpawn(value)
    local model = parseModels(value.model)[1]
    if not model then return notice('destructive', 'Enter a model name.') end
    look = readLook(value)
    local entity, typeOrErr = spawnSubject(model, value.location)
    if not entity then return refresh(notice('destructive', typeOrErr)) end
    return refresh(notice('success', ('%s ready at %s.'):format(model, Scene.location().label)))
end

local function needSubject()
    if Scene.current() then return nil end
    return notice('destructive', 'Spawn something first (Scene → Spawn).')
end

local function photoOptions(value)
    if Scene.isGreen() then
        local bg = value.background or 'transparent'
        return {
            key = bg ~= 'green', background = bg, crop = bg ~= 'green',
            maxSize = tonumber(value.size) or 0, format = 'png', aspect = tonumber(value.aspect) or 0,
        }
    end
    return {
        key = false, crop = false, aspect = tonumber(value.aspect) or 0,
        maxSize = tonumber(value.size) or 0, format = value.format == 'jpg' and 'jpg' or 'png', quality = 0.95,
    }
end

local function takePhotos(value)
    local discordWanted = value.discord == true
    local _, derr = discordTarget(discordWanted, nil)
    if derr then return notice('destructive', derr) end

    local models = parseModels(value.models)
    if #models == 0 then
        local err = needSubject()
        if err then return err end
        local _, current = Scene.current()
        models = { current }
    end
    local angles = type(value.angles) == 'table' and #value.angles > 0 and value.angles or { 'current' }
    local lens = value.lens or frame.lens
    local opts = photoOptions(value)

    local done, failed = 0, {}
    for index, model in ipairs(models) do
        local entity, currentModel, entityType = Scene.current()
        if index > 1 or currentModel ~= model or not entity then
            entity, entityType = spawnSubject(model)
        end
        if not entity then
            failed[#failed + 1] = entityType
        else
            Scene.setLens(lens)
            Scene.setDof(value.dof == true)
            for _, angle in ipairs(angles) do
                local angleId = angle == 'current' and frame.angle or angle
                local zoom = angle == 'current' and frame.zoom or clampNumber(value.zoom, 0.2, 5.0, 1.0)
                local cam, target = Shots.angle(angleId, Scene.context(), zoom)
                if cam then
                    Scene.look(cam, target)
                    Wait(value.dof and 450 or 200)
                    local label = ('%s (%s)'):format(model, Shots.angleLabel[angleId] or angleId)
                    local discord = discordWanted and { url = settings.webhook, content = ('**%s** · %s · %s'):format(model, entityType, Shots.angleLabel[angleId] or angleId) } or nil
                    local libraryShot = Scene.isGreen() and opts.key
                    local meta = libraryShot
                        and { kind = 'entity', type = entityType, model = model, angle = angleId }
                        or { kind = 'shot', model = model, angle = angleId }
                    local result = Capture.photo(meta, opts, discord)
                    recordResult(label, entityType, result)
                    if result.ok then done = done + 1 else failed[#failed + 1] = ('%s/%s: %s'):format(model, angleId, result.error) end
                end
            end
        end
    end
    applyFrame()

    if done == 0 then return refresh(notice('destructive', failed[1] or 'Nothing captured.')) end
    local message = ('Captured %d/%d.'):format(done, done + #failed)
    if #failed > 0 then message = message .. ' First failure: ' .. failed[1] end
    return refresh(notice(#failed > 0 and 'warning' or 'success', message))
end

local function shootVideo(value)
    local err = needSubject()
    if err then return err end
    local preview = value.preview == true
    local discord, derr = discordTarget(not preview and value.discord == true, nil)
    if derr then return notice('destructive', derr) end

    local _, model, entityType = Scene.current()
    local seconds = clampNumber(value.seconds, 2, 60, 10)
    Scene.setLens(value.lens or frame.lens)
    Scene.setDof(value.dof == true)
    local eval, used = Shots.move(value.motion or 'orbit', Scene.context(), {
        seconds = seconds, pitch = tonumber(value.height) or 12, zoom = clampNumber(value.zoom, 0.2, 5.0, 1.0),
    })
    local function at(t)
        local cam, target = eval(t)
        Scene.look(cam, target)
    end
    at(0.0)
    Wait(value.dof and 450 or 200)

    local job
    if not preview then
        local bg = value.background or 'black'
        local errStart
        job, errStart = Capture.startVideo({ kind = 'video', model = model, motion = used }, {
            key = Scene.isGreen() and bg ~= 'green',
            background = bg,
            height = tonumber(value.quality) or 1080,
            fps = 30,
            seconds = seconds,
            discord = discord ~= nil,
            aspect = tonumber(value.aspect) or 0,
        })
        if not job then
            applyFrame()
            return notice('destructive', errStart)
        end
    end

    if value.shake then Scene.setShake(0.25) end
    local startedAt, duration = GetGameTimer(), seconds * 1000
    while true do
        local t = (GetGameTimer() - startedAt) / duration
        if t >= 1.0 then break end
        at(t)
        Wait(0)
    end
    at(1.0)
    Scene.setShake(0)

    if preview then
        applyFrame()
        return notice('success', ('Previewed %s. Untick "Preview only" to record it.'):format(Shots.moveLabel[used]))
    end

    if discord then discord.content = ('**%s** · %s · %s · %ds'):format(model, entityType, Shots.moveLabel[used], seconds) end
    local result = Capture.stopVideo(job, discord)
    applyFrame()
    recordResult(('%s · %s'):format(model, Shots.moveLabel[used]), 'video', result)
    if not result.ok then return refresh(notice('destructive', result.error or 'Recording failed.')) end
    local message = ('Saved %s (%s).'):format(result.path, fmtBytes(result.bytes))
    if used ~= value.motion and value.motion == 'details' then message = message .. ' Detail fly-around is vehicles only, so it orbited instead.' end
    if result.discord and not result.discord.ok then return refresh(notice('warning', message .. ' Discord: ' .. result.discord.error)) end
    return refresh(notice('success', message))
end

-- ------------------------------------------------------------------ screen

local function sceneDiscordContent(kind)
    return ('%s from %s'):format(kind, GetPlayerName(PlayerId()) or 'admin')
end

local function takeScreenPhoto(value)
    local discord, derr = discordTarget(value.discord == true, sceneDiscordContent('Screenshot'))
    if derr then return notice('destructive', derr) end
    Scene.leave()

    local hiding = value.hideHud ~= false
    if hiding then
        CreateThread(function()
            while hiding do HideHudAndRadarThisFrame() Wait(0) end
        end)
        Wait(100)
    end
    local format = value.format == 'png' and 'png' or 'jpg'
    local result = Capture.photo({ kind = 'scene' }, { key = false, format = format, quality = 0.92, aspect = tonumber(value.aspect) or 0 }, discord)
    hiding = false

    recordResult('Screenshot', 'photo', result)
    if not result.ok then return refresh(notice('destructive', result.error or 'Screenshot failed.')) end
    return refresh(notice('success', ('Saved %s (%s).'):format(result.path, fmtBytes(result.bytes))))
end

-- Runs with the panel closed so the player can move; X stops early.
local function recordScreenClip(value)
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
        aspect = tonumber(value.aspect) or 0,
    })
    if not job then return notify(err, 'error') end

    local deadline = GetGameTimer() + seconds * 1000
    while GetGameTimer() < deadline do
        if hideHud then HideHudAndRadarThisFrame() end
        DisableControlAction(0, STOP_CONTROL, true)
        if IsDisabledControlJustPressed(0, STOP_CONTROL) then break end
        Wait(0)
    end

    local result = Capture.stopVideo(job, discord)
    recordResult('Gameplay clip', 'video', result)
    if not result.ok then return notify(result.error or 'Recording failed.', 'error') end
    local message = ('Saved %s (%s).'):format(result.path, fmtBytes(result.bytes))
    if result.discord then
        message = message .. (result.discord.ok and ' Posted to Discord.' or (' Discord: ' .. result.discord.error))
    end
    notify(message, (result.discord and not result.discord.ok) and 'warning' or 'success')
end

-- ------------------------------------------------------------- environment

local function applyEnv(value)
    Env.apply({ weather = value.weather, hour = value.hour, minute = value.minute })
    Env.setLook(value.look, (tonumber(value.strength) or 100) / 100)
end

-- ---------------------------------------------------------------- actions

local function handleAction(actionId, context)
    local value = type(context.value) == 'table' and context.value or {}

    if actionId == 'spawn' then
        return doSpawn(value)
    elseif actionId == 'pose' then
        pose = readPose(value)
        Scene.pose(pose)
        return needSubject() or notice('success', 'Vehicle posed.')
    elseif actionId == 'frame' then
        frame = readFrame(value)
        applyFrame()
        return needSubject() or notice('success', 'Camera framed. Photos with "Current framing" use this.')
    elseif actionId == 'photo' then
        return takePhotos(value)
    elseif actionId == 'video' then
        return shootVideo(value)
    elseif actionId == 'leave' then
        Scene.leave()
        return refresh(notice('success', 'Scene cleared.'))
    elseif actionId == 'env-apply' then
        applyEnv(value)
        return refresh(notice('success', 'Applied locally. Closing the tool returns to the server weather.'))
    elseif actionId == 'env-reset' then
        Env.restore()
        return refresh(notice('success', 'Back to the server weather and time.'))
    elseif actionId == 'scene-photo' then
        return takeScreenPhoto(value)
    elseif actionId == 'scene-video' then
        if value.discord == true and not isWebhook(settings.webhook) then
            return notice('destructive', 'Set a Discord webhook in the Discord tab first.')
        end
        Scene.leave()
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

-- Live preview: pose, framing and environment follow the form as it's edited.
local function handleChange(actionId, context)
    local value = type(context.value) == 'table' and context.value or {}
    if actionId == 'pose' then
        pose = readPose(value)
        Scene.pose(pose)
    elseif actionId == 'frame' then
        frame = readFrame(value)
        if Scene.current() then applyFrame() end
    elseif actionId == 'env-apply' then
        applyEnv(value)
    elseif actionId == 'discord-save' then
        if isWebhook(value.webhook) then saveWebhook(value.webhook) end
    end
end

-- ------------------------------------------------------------- definition

local function options(list, labelOf)
    local out = {}
    for _, item in ipairs(list) do out[#out + 1] = { value = item.id, label = labelOf and labelOf(item) or item.label } end
    return out
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

local function aspectField(default)
    return { id = 'aspect', label = 'Shape', type = 'select', default = default or '0', options = ASPECTS }
end

local function statsBlock()
    local entity, model, entityType = Scene.current()
    local loc = Scene.location()
    local env = Env.current()
    return {
        type = 'stats',
        items = {
            { label = 'Location', value = loc and loc.label or 'Not set up', icon = 'MapPin', tone = loc and 'success' or 'neutral' },
            { label = 'Subject', value = entity and model or 'None', description = entityType, icon = 'Car' },
            { label = 'Weather', value = ('%s %02d:%02d'):format(pretty(env.weather), env.hour, env.minute),
              description = Env.isCustom() and 'local override' or 'server', icon = 'Sparkles', tone = Env.isCustom() and 'primary' or 'neutral' },
            { label = 'Discord', value = isWebhook(settings.webhook) and 'Ready' or 'Not set', icon = 'MessageSquare',
              tone = isWebhook(settings.webhook) and 'success' or 'warning' },
        },
    }
end

local function historyBlock()
    if #history == 0 then
        return { type = 'empty', title = 'Nothing captured yet', description = 'Photos and videos from this session show up here.', icon = 'Camera' }
    end
    return { type = 'list', id = 'history', title = 'This session', layout = 'list', items = history }
end

local function shootView()
    return {
        id = 'shoot',
        label = 'Shoot',
        icon = 'Camera',
        content = {
            title = 'Studio',
            description = 'Spawn → pose → frame → shoot. Pose, framing and the Environment tab update live as you edit.',
            blocks = {
                statsBlock(),
                {
                    type = 'actions',
                    title = 'Scene',
                    actions = {
                        {
                            id = 'spawn', label = 'Spawn', icon = 'Car', variant = 'primary', submitLabel = 'Spawn',
                            fields = {
                                { id = 'model', label = 'Model', type = 'text', required = true, placeholder = 'zentorno, a_m_y_hipster_01, prop_bench_01a' },
                                { id = 'location', label = 'Location', type = 'select', default = lastLocation, options = options(Scene.locations) },
                                { id = 'customPaint', label = 'Custom paint', type = 'checkbox', default = look.customPaint },
                                { id = 'paint', label = 'Paint colour', type = 'color', default = look.paint },
                                { id = 'tuned', label = 'Fully tuned (max upgrades, xenons, tint)', type = 'checkbox', default = look.tuned },
                                { id = 'neon', label = 'Neon', type = 'checkbox', default = look.neon },
                                { id = 'neonColour', label = 'Neon colour', type = 'color', default = look.neonColour },
                                { id = 'plate', label = 'Plate text', type = 'text', default = look.plate, maxLength = 8 },
                                { id = 'dirty', label = 'Dirty', type = 'checkbox', default = look.dirty },
                            },
                        },
                        {
                            id = 'pose', label = 'Vehicle pose', icon = 'Key', variant = 'secondary', submitLabel = 'Apply',
                            fields = {
                                { id = 'doors', label = 'Open', type = 'multiselect', default = pose.doors, options = DOOR_OPTIONS },
                                { id = 'lights', label = 'Lights', type = 'select', default = pose.lights, options = {
                                    { value = 'off', label = 'Off' }, { value = 'on', label = 'On' }, { value = 'full', label = 'Full beam' },
                                } },
                                { id = 'steer', label = 'Wheels', type = 'select', default = pose.steer, options = {
                                    { value = 'straight', label = 'Straight' }, { value = 'left', label = 'Turned left' }, { value = 'right', label = 'Turned right' },
                                } },
                                { id = 'engine', label = 'Engine running', type = 'checkbox', default = pose.engine },
                                { id = 'interior', label = 'Interior light', type = 'checkbox', default = pose.interior },
                                { id = 'roof', label = 'Roof down (convertibles)', type = 'checkbox', default = pose.roof },
                            },
                        },
                        { id = 'leave', label = 'Clear scene', icon = 'DoorOpen', variant = 'outline' },
                    },
                },
                {
                    type = 'actions',
                    title = 'Camera',
                    actions = {
                        {
                            id = 'frame', label = 'Frame camera', icon = 'Crosshair', variant = 'secondary', submitLabel = 'Frame',
                            fields = {
                                { id = 'angle', label = 'Angle', type = 'select', default = frame.angle, options = (function()
                                    local list = {}
                                    for _, a in ipairs(Shots.angles) do if a.id ~= 'current' then list[#list + 1] = { value = a.id, label = a.label } end end
                                    return list
                                end)() },
                                { id = 'lens', label = 'Lens', type = 'select', default = frame.lens, options = LENSES },
                                { id = 'zoom', label = 'Zoom', type = 'range', default = frame.zoom, min = 0.3, max = 3, step = 0.05 },
                                { id = 'dof', label = 'Depth of field (blur the background)', type = 'checkbox', default = frame.dof },
                            },
                        },
                        {
                            id = 'photo', label = 'Take photos', icon = 'Camera', variant = 'primary', submitLabel = 'Capture',
                            fields = {
                                { id = 'angles', label = 'Angles', type = 'multiselect', required = true, default = { 'current' }, options = options(Shots.angles) },
                                { id = 'models', label = 'Batch models (optional)', type = 'textarea', rows = 2,
                                  placeholder = 'Blank = current subject. Or: adder, zentorno, t20',
                                  description = 'Each model is spawned here with the same paint and pose.' },
                                { id = 'lens', label = 'Lens', type = 'select', default = frame.lens, options = LENSES },
                                { id = 'zoom', label = 'Zoom (preset angles)', type = 'range', default = 1, min = 0.3, max = 3, step = 0.05 },
                                { id = 'dof', label = 'Depth of field', type = 'checkbox', default = frame.dof },
                                { id = 'background', label = 'Studio background', type = 'select', default = 'transparent', options = {
                                    { value = 'transparent', label = 'Transparent' }, { value = 'black', label = 'Black' },
                                    { value = 'white', label = 'White' }, { value = 'green', label = 'Green (no keying)' },
                                }, description = 'Green screen studio only. Transparent shots go to the image library.' },
                                aspectField('1.7778'),
                                { id = 'format', label = 'Format (real locations)', type = 'select', default = 'png', options = {
                                    { value = 'png', label = 'PNG' }, { value = 'jpg', label = 'JPEG' },
                                } },
                                { id = 'size', label = 'Max size', type = 'select', default = '0', options = {
                                    { value = '0', label = 'Full' }, { value = '2048', label = '2048 px' }, { value = '1024', label = '1024 px' },
                                    { value = '512', label = '512 px' }, { value = '256', label = '256 px' },
                                } },
                                discordField(),
                            },
                        },
                        {
                            id = 'video', label = 'Record video', icon = 'CircleDot', variant = 'primary', submitLabel = 'Roll camera',
                            fields = {
                                { id = 'motion', label = 'Move', type = 'select', default = 'montage', options = options(Shots.moves) },
                                { id = 'seconds', label = 'Length (seconds)', type = 'number', default = 12, min = 2, max = 60, wholeNumber = true,
                                  description = 'Detail fly-around: ~1.3 s per detail.' },
                                { id = 'lens', label = 'Lens', type = 'select', default = '24', options = LENSES },
                                { id = 'zoom', label = 'Zoom', type = 'range', default = 1, min = 0.3, max = 3, step = 0.05 },
                                { id = 'height', label = 'Camera height', type = 'select', default = '12', options = {
                                    { value = '3', label = 'Low' }, { value = '12', label = 'Mid' }, { value = '30', label = 'High' },
                                } },
                                { id = 'dof', label = 'Depth of field', type = 'checkbox', default = true },
                                { id = 'shake', label = 'Handheld shake', type = 'checkbox', default = false },
                                aspectField('2.3333'),
                                qualityField(),
                                { id = 'background', label = 'Studio background', type = 'select', default = 'black', options = {
                                    { value = 'black', label = 'Black' }, { value = 'white', label = 'White' }, { value = 'green', label = 'Green screen' },
                                } },
                                { id = 'preview', label = 'Preview only (don\'t record)', type = 'checkbox', default = false },
                                discordField(),
                            },
                        },
                    },
                },
            },
        },
    }
end

local function environmentView()
    local env = Env.current()
    local weatherOptions = {}
    for _, w in ipairs(Env.weatherTypes()) do weatherOptions[#weatherOptions + 1] = { value = w, label = pretty(w) } end
    local l = Env.look()
    return {
        id = 'environment',
        label = 'Environment',
        icon = 'Sparkles',
        content = {
            title = 'Weather, time & look',
            description = 'Only you see this, only while the tool is open. Server weather can\'t override it meanwhile; closing the tool hands it back.',
            blocks = {
                {
                    type = 'form', id = 'env-form', action = { id = 'env-apply', label = 'Apply' }, submitLabel = 'Apply',
                    fields = {
                        { id = 'weather', label = 'Weather', type = 'select', default = env.weather, options = weatherOptions },
                        { id = 'hour', label = 'Hour', type = 'range', default = env.hour, min = 0, max = 23, step = 1 },
                        { id = 'minute', label = 'Minute', type = 'select', default = tostring(env.minute - env.minute % 15), options = {
                            { value = '0', label = ':00' }, { value = '15', label = ':15' }, { value = '30', label = ':30' }, { value = '45', label = ':45' },
                        } },
                        { id = 'look', label = 'Colour grade', type = 'select', default = l.name, options = Env.looks },
                        { id = 'strength', label = 'Grade strength', type = 'range', default = math.floor(l.strength * 100), min = 0, max = 100, step = 5 },
                    },
                },
                { type = 'actions', actions = { { id = 'env-reset', label = 'Back to server weather', icon = 'RotateCcw', variant = 'outline' } } },
            },
        },
    }
end

appDefinition = function()
    return {
        id = APP_ID,
        title = 'Image Maker',
        description = 'Photos & cinematic video',
        icon = 'Camera',
        placement = 'left',
        draggable = true,
        rememberPosition = true,
        defaultView = 'shoot',
        navigation = {
            shootView(),
            environmentView(),
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
                                        aspectField('0'),
                                        { id = 'hideHud', label = 'Hide HUD', type = 'checkbox', default = true },
                                        discordField(),
                                    },
                                },
                                {
                                    id = 'scene-video', label = 'Record clip', icon = 'CircleDot', variant = 'secondary', submitLabel = 'Start recording',
                                    fields = {
                                        { id = 'seconds', label = 'Max length (seconds)', type = 'number', default = 15, min = 2, max = 120, wholeNumber = true,
                                          description = 'The panel closes while recording. Press X to stop early.' },
                                        aspectField('0'),
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
    local viewId = 'shoot'
    while true do
        Kora.nui.openApp(APP_ID, { viewId = viewId })
        if not pendingScene then break end
        local value = pendingScene
        pendingScene = nil
        local ok, err = pcall(recordScreenClip, value)
        if not ok then notify('Recording failed: ' .. tostring(err), 'error') end
        Kora.nui.updateApp(APP_ID, { navigation = appDefinition().navigation })
        viewId = 'scene'
    end
    -- openApp returns on any close (X, Escape, resource stop): never leave the
    -- player hidden and frozen, and hand weather/time back to the server.
    Scene.leave()
    Env.restore()
    opening = false
end

RegisterNetEvent('kora_image_maker:client:open', function()
    if source ~= 65535 then return end
    CreateThread(open)
end)
