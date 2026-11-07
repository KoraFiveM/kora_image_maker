-- Studio core, in three sections: Env (local weather/time/grade), Scene
-- (location, subject, camera) and Shots (angles and camera moves).
--
-- Kept in this one file on purpose: the running server caches each
-- resource's fxmanifest until a global `refresh`, and this name is the one it
-- already knows. Split it again only together with a manifest change and a
-- refresh (a full server restart does one).

-- ======================================================================= Env
-- Local-only weather, time and colour grade while the tool is in use.
--
-- kora_weathersync is paused through its own qb-weathersync DisableSync /
-- EnableSync events, so its once-a-second clock loop and state-bag updates
-- stop touching this client: nothing here has to loop to hold the override.
-- Closing the tool hands control back and the server state is reapplied.

ImageMaker = ImageMaker or {}
local Env = {}
ImageMaker.env = Env

local FALLBACK_WEATHER = {
    'EXTRASUNNY', 'CLEAR', 'NEUTRAL', 'SMOG', 'FOGGY', 'OVERCAST', 'CLOUDS', 'CLEARING',
    'RAIN', 'THUNDER', 'SNOW', 'BLIZZARD', 'SNOWLIGHT', 'XMAS', 'HALLOWEEN',
}
local SNOWY = { SNOW = true, BLIZZARD = true, SNOWLIGHT = true, XMAS = true }

-- Rockstar Editor / Snapmatic timecycle grades.
Env.looks = {
    { value = 'none', label = 'None' },
    { value = 'NG_filmic01', label = 'Film: Vintage' },
    { value = 'NG_filmic02', label = 'Film: Warm' },
    { value = 'NG_filmic04', label = 'Film: Faded' },
    { value = 'NG_filmic06', label = 'Film: Teal & orange' },
    { value = 'NG_filmic10', label = 'Film: Cold' },
    { value = 'NG_filmic14', label = 'Film: High contrast' },
    { value = 'NG_filmic20', label = 'Film: Dusk' },
    { value = 'NG_filmic22', label = 'Film: Bleach' },
    { value = 'phone_cam3', label = 'Snapmatic: Noir' },
    { value = 'phone_cam9', label = 'Snapmatic: Sepia' },
    { value = 'phone_cam12', label = 'Snapmatic: Vivid' },
}
local lookValues = {}
for _, l in ipairs(Env.looks) do lookValues[l.value] = true end

local suspended = false
local current -- { weather, hour, minute }
local look = { name = 'none', strength = 1.0 }

function Env.weatherTypes()
    local ok, list = pcall(function() return exports.kora_weathersync:getWeatherTypes() end)
    if ok and type(list) == 'table' and #list > 0 then return list end
    return FALLBACK_WEATHER
end

---The server's weather/time right now (what the tool returns to).
function Env.serverState()
    local s = GlobalState.kora_weathersync
    if type(s) == 'table' and type(s.weather) == 'string' then
        return { weather = s.weather, hour = tonumber(s.hour) or GetClockHours(), minute = tonumber(s.minute) or GetClockMinutes() }
    end
    return { weather = 'CLEAR', hour = GetClockHours(), minute = GetClockMinutes() }
end

function Env.isCustom() return suspended end
function Env.current() return current or Env.serverState() end
function Env.look() return look end

local function applyWeather(weather)
    ClearOverrideWeather()
    ClearWeatherTypePersist()
    SetWeatherTypePersist(weather)
    SetWeatherTypeNow(weather)
    SetWeatherTypeNowPersist(weather)
    SetRainLevel(-1.0) -- the weather type's own rain
    SetForceVehicleTrails(SNOWY[weather] == true)
    SetForcePedFootstepsTracks(SNOWY[weather] == true)
end

---Applies any of { weather, hour, minute } locally, once.
function Env.apply(opts)
    opts = opts or {}
    if not suspended then
        current = Env.serverState()
        suspended = true
        TriggerEvent('qb-weathersync:client:DisableSync') -- runs synchronously; we apply over it below
    end
    if type(opts.weather) == 'string' and opts.weather ~= '' then current.weather = opts.weather:upper() end
    local hour, minute = tonumber(opts.hour), tonumber(opts.minute)
    if hour then current.hour = math.floor(math.max(0, math.min(23, hour))) end
    if minute then current.minute = math.floor(math.max(0, math.min(59, minute))) end

    applyWeather(current.weather)
    NetworkOverrideClockTime(current.hour, current.minute, 0)
end

function Env.setLook(name, strength)
    look.name = lookValues[name] and name or 'none'
    look.strength = math.max(0.0, math.min(1.0, tonumber(strength) or 1.0))
    if look.name == 'none' then
        ClearTimecycleModifier()
    else
        SetTimecycleModifier(look.name)
        SetTimecycleModifierStrength(look.strength)
    end
end

---Hands weather/time back to the server and clears the colour grade.
function Env.restore()
    if look.name ~= 'none' then ClearTimecycleModifier() end
    look = { name = 'none', strength = 1.0 }
    if not suspended then return end
    suspended, current = false, nil

    SetForceVehicleTrails(false)
    SetForcePedFootstepsTracks(false)
    if GetResourceState('kora_weathersync') == 'started' then
        TriggerEvent('qb-weathersync:client:EnableSync')
    else
        ClearOverrideWeather()
        ClearWeatherTypePersist()
        SetRainLevel(-1.0)
        NetworkClearClockTimeOverride()
    end
end

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    Env.restore()
end)

-- ===================================================================== Scene
-- Scene: where the subject is shot. Everything sits on real ground: either the
-- green-screen studio (green walls drawn around a flat spot) or a real
-- location, including wherever the player is standing. Owns the subject
-- entity, its styling/pose, and the scripted camera.

ImageMaker = ImageMaker or {}
local Scene = {}
ImageMaker.scene = Scene

local GREEN = { 0, 255, 0 }
local COLLISION_TIMEOUT = 6000
local DEFAULT_FOV = 35.0

Scene.locations = {
    { id = 'studio', label = 'Green screen studio', coords = vec4(-1336.0, -3044.0, 13.94, 330.0), green = true },
    { id = 'here', label = 'Where I am standing', here = true },
    { id = 'lsia', label = 'LSIA runway', coords = vec4(-1336.0, -3044.0, 13.94, 240.0) },
    { id = 'mazebank', label = 'Maze Bank Tower roof', coords = vec4(-75.0, -818.0, 326.2, 200.0) },
    { id = 'pier', label = 'Del Perro Pier', coords = vec4(-1850.1, -1231.7, 13.0, 50.0) },
    { id = 'kortz', label = 'Kortz Center', coords = vec4(-2243.8, 264.5, 174.6, 25.0) },
    { id = 'chiliad', label = 'Mount Chiliad summit', coords = vec4(450.7, 5566.6, 806.2, 300.0) },
    { id = 'sandy', label = 'Sandy Shores airfield', coords = vec4(1747.0, 3273.7, 41.1, 105.0) },
}
local locationById = {}
for _, loc in ipairs(Scene.locations) do locationById[loc.id] = loc end

local state = {
    active = false,
    location = nil,
    origin = nil,      -- vec4 where the subject stands
    green = false,
    floorZ = nil,
    half = 15.0,
    cam = nil,
    fov = DEFAULT_FOV,
    dof = false,
    steer = 0.0,
    entity = nil, model = nil, type = nil,
    min = nil, max = nil, center = nil, radius = nil,
    returnTo = nil,
}

-- ------------------------------------------------------------- green room

local function quad(a, b, c, d)
    local r, g, bl = GREEN[1], GREEN[2], GREEN[3]
    DrawPoly(a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z, r, g, bl, 255)
    DrawPoly(c.x, c.y, c.z, b.x, b.y, b.z, a.x, a.y, a.z, r, g, bl, 255)
    DrawPoly(c.x, c.y, c.z, d.x, d.y, d.z, a.x, a.y, a.z, r, g, bl, 255)
    DrawPoly(a.x, a.y, a.z, d.x, d.y, d.z, c.x, c.y, c.z, r, g, bl, 255)
end

local function drawRoom()
    local o, h, z = state.origin, state.half, state.floorZ
    local c = {
        vector3(o.x - h, o.y - h, z), vector3(o.x + h, o.y - h, z),
        vector3(o.x + h, o.y + h, z), vector3(o.x - h, o.y + h, z),
    }
    local up = vector3(0.0, 0.0, h)
    quad(c[1], c[2], c[3], c[4])
    quad(c[1] + up, c[2] + up, c[3] + up, c[4] + up)
    for i = 1, 4 do
        local a, b = c[i], c[i % 4 + 1]
        quad(a, b, b + up, a + up)
    end
end

-- Highest ground within the room's footprint, so no bump pokes through the floor.
local function studioFloor(o)
    local top
    for dx = -8, 8, 8 do
        for dy = -8, 8, 8 do
            local ok, gz = GetGroundZFor_3dCoord(o.x + dx, o.y + dy, o.z + 3.0, false)
            if ok and (not top or gz > top) then top = gz end
        end
    end
    return (top or o.z) + 0.03
end

-- ------------------------------------------------------------- lifecycle

function Scene.isActive() return state.active end
function Scene.location() return state.location and locationById[state.location] or nil end
function Scene.isGreen() return state.active and state.green end
function Scene.current() return state.entity, state.model, state.type end

local function hidePlayer(ped)
    SetEntityVisible(ped, false, false)
    SetEntityCollision(ped, false, false)
    SetEntityInvincible(ped, true)
    FreezeEntityPosition(ped, true)
end

local function waitForCollision(ped, x, y, z)
    RequestCollisionAtCoord(x, y, z)
    local deadline = GetGameTimer() + COLLISION_TIMEOUT
    while not HasCollisionLoadedAroundEntity(ped) and GetGameTimer() < deadline do
        RequestCollisionAtCoord(x, y, z)
        Wait(50)
    end
end

local function groundAt(x, y, z)
    local ok, gz = GetGroundZFor_3dCoord(x, y, z + 2.0, false)
    return ok and gz or z
end

local function startLoop()
    CreateThread(function()
        while state.active do
            if state.green then drawRoom() end
            HideHudAndRadarThisFrame()
            -- Keep traffic and pedestrians out of the shot.
            SetVehicleDensityMultiplierThisFrame(0.0)
            SetRandomVehicleDensityMultiplierThisFrame(0.0)
            SetParkedVehicleDensityMultiplierThisFrame(0.0)
            SetPedDensityMultiplierThisFrame(0.0)
            SetScenarioPedDensityMultiplierThisFrame(0.0, 0.0)
            if state.dof then SetUseHiDof() end
            if state.steer ~= 0.0 and state.entity and DoesEntityExist(state.entity) then
                SetVehicleSteeringAngle(state.entity, state.steer)
            end
            Wait(0)
        end
    end)
end

local function removeEntity()
    if state.entity and DoesEntityExist(state.entity) then Kora.entities.remove(state.entity) end
    state.entity, state.model, state.type = nil, nil, nil
    state.min, state.max, state.center, state.radius = nil, nil, nil, nil
    state.steer = 0.0
end

---@return boolean ok, string? error
function Scene.enter(locationId)
    local loc = locationById[locationId] or locationById.studio
    if state.active and state.location == loc.id then return true end
    if state.active then Scene.leave() end

    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, false) then return false, 'Get out of your vehicle first.' end

    local coords, heading = GetEntityCoords(ped), GetEntityHeading(ped)
    state.returnTo = { coords = coords, heading = heading }
    hidePlayer(ped)

    local origin
    if loc.here then
        origin = vector4(coords.x, coords.y, groundAt(coords.x, coords.y, coords.z), heading)
    else
        local c = loc.coords
        SetEntityCoords(ped, c.x, c.y, c.z + 1.0, false, false, false, false)
        waitForCollision(ped, c.x, c.y, c.z)
        origin = vector4(c.x, c.y, groundAt(c.x, c.y, c.z), c.w)
    end

    state.active, state.location, state.origin, state.green = true, loc.id, origin, loc.green == true
    state.floorZ = state.green and studioFloor(origin) or nil
    state.half = 15.0
    SetFocusPosAndVel(origin.x, origin.y, origin.z, 0.0, 0.0, 0.0)
    ClearAreaOfVehicles(origin.x, origin.y, origin.z, 40.0, false, false, false, false, false)
    ClearAreaOfPeds(origin.x, origin.y, origin.z, 40.0, 1)

    state.cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    state.fov = DEFAULT_FOV
    SetCamFov(state.cam, state.fov)
    local h = math.rad(origin.w)
    SetCamCoord(state.cam, origin.x - math.sin(h) * 8.0, origin.y + math.cos(h) * 8.0, origin.z + 2.0)
    PointCamAtCoord(state.cam, origin.x, origin.y, origin.z + 0.5)
    SetCamActive(state.cam, true)
    RenderScriptCams(true, false, 0, true, true)

    startLoop()
    return true
end

function Scene.leave()
    if not state.active then return end
    state.active = false
    removeEntity()

    if state.cam and DoesCamExist(state.cam) then
        StopCamShaking(state.cam, true)
        SetCamActive(state.cam, false)
        DestroyCam(state.cam, false)
    end
    RenderScriptCams(false, false, 0, true, true)
    state.cam, state.dof, state.location = nil, false, nil
    ClearFocus()

    local ped = PlayerPedId()
    local back = state.returnTo
    state.returnTo = nil
    if back then
        SetEntityCoords(ped, back.coords.x, back.coords.y, back.coords.z, false, false, false, false)
        SetEntityHeading(ped, back.heading)
    end
    FreezeEntityPosition(ped, false)
    SetEntityCollision(ped, true, true)
    SetEntityInvincible(ped, false)
    SetEntityVisible(ped, true, false)
end

-- ----------------------------------------------------------------- subject

---@return string|nil 'veh' | 'ped' | 'obj', or nil if the model doesn't exist
function Scene.modelType(model)
    local hash = type(model) == 'number' and model or joaat(model)
    if not IsModelInCdimage(hash) or not IsModelValid(hash) then return nil end
    if IsModelAVehicle(hash) then return 'veh' end
    if IsModelAPed(hash) then return 'ped' end
    return 'obj'
end

-- Lets a vehicle settle onto its wheels on the real ground, then freezes it.
local function settleVehicle(entity)
    SetVehicleHandbrake(entity, true)
    FreezeEntityPosition(entity, false)
    ActivatePhysics(entity)
    SetVehicleOnGroundProperly(entity)
    Wait(250)
    local deadline = GetGameTimer() + 2500
    while GetGameTimer() < deadline do
        if IsVehicleOnAllWheels(entity) and GetEntitySpeed(entity) < 0.02 then break end
        Wait(50)
    end
    Wait(100)
    FreezeEntityPosition(entity, true)
end

---@return integer|false entity, string? typeOrError
function Scene.spawn(model)
    if not state.active then return false, 'No scene is set up.' end
    local entityType = Scene.modelType(model)
    if not entityType then return false, ('Unknown model "%s".'):format(model) end

    removeEntity()
    local o = state.origin
    local lift = entityType == 'obj' and 0.0 or 1.0
    local entity, err = Kora.entities.create(model, vector3(o.x, o.y, o.z + lift), { preset = 'static', heading = o.w })
    if not entity then return false, ('Could not spawn %s: %s'):format(model, tostring(err)) end

    if entityType == 'veh' then
        SetVehicleEngineOn(entity, false, true, true)
        SetVehicleDirtLevel(entity, 0.0)
        settleVehicle(entity)
    elseif entityType == 'ped' then
        SetPedDefaultComponentVariation(entity)
    else
        PlaceObjectOnGroundProperly(entity)
    end

    local min, max = GetModelDimensions(GetEntityModel(entity))
    state.entity, state.model, state.type = entity, model, entityType
    state.min, state.max = min, max
    state.center = (min + max) / 2
    state.radius = math.max(#(max - min) / 2, 0.15)
    state.half = math.max(15.0, math.min(60.0, state.radius * 5.0))

    -- High-detail textures and LODs need a moment to stream in.
    Wait(500)
    return entity, entityType
end

local function hexToRgb(hex)
    if type(hex) ~= 'string' then return nil end
    local r, g, b = hex:match('^#?(%x%x)(%x%x)(%x%x)$')
    if not r then return nil end
    return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
end

-- Mods 23/24 (wheels) and 48 (livery) are left alone: "max" there is just the
-- last item in a list, not an upgrade.
local SKIP_MODS = { [23] = true, [24] = true, [48] = true }

---@param look table { paint?: '#rrggbb', tuned?: boolean, neon?: '#rrggbb'|false, plate?: string, dirty?: boolean }
function Scene.style(look)
    local e = state.entity
    if state.type ~= 'veh' or not e or not DoesEntityExist(e) or type(look) ~= 'table' then return end
    SetVehicleModKit(e, 0)

    local r, g, b = hexToRgb(look.paint)
    if r then
        SetVehicleCustomPrimaryColour(e, r, g, b)
        SetVehicleCustomSecondaryColour(e, r, g, b)
    end

    if look.tuned then
        for mod = 0, 49 do
            if not SKIP_MODS[mod] then
                local count = GetNumVehicleMods(e, mod)
                if count > 0 then SetVehicleMod(e, mod, count - 1, false) end
            end
        end
        ToggleVehicleMod(e, 18, true) -- turbo
        ToggleVehicleMod(e, 22, true) -- xenon
        SetVehicleWindowTint(e, 1)
    end

    local nr, ng, nb = hexToRgb(look.neon)
    for i = 0, 3 do SetVehicleNeonLightEnabled(e, i, nr ~= nil) end
    if nr then SetVehicleNeonLightsColour(e, nr, ng, nb) end

    if type(look.plate) == 'string' and look.plate ~= '' then SetVehicleNumberPlateText(e, look.plate:sub(1, 8)) end
    SetVehicleDirtLevel(e, look.dirty and 12.0 or 0.0)
end

local DOORS = { front = { 0, 1 }, rear = { 2, 3 }, hood = { 4 }, trunk = { 5 } }
local STEER = { straight = 0.0, left = 35.0, right = -35.0 }

---@param pose table { doors?: string[], lights?: 'off'|'on'|'full', steer?: 'straight'|'left'|'right', roof?: boolean, engine?: boolean, interior?: boolean }
function Scene.pose(pose)
    local e = state.entity
    if state.type ~= 'veh' or not e or not DoesEntityExist(e) or type(pose) ~= 'table' then return end

    local open = {}
    for _, key in ipairs(type(pose.doors) == 'table' and pose.doors or {}) do open[key] = true end
    for key, doors in pairs(DOORS) do
        for _, door in ipairs(doors) do
            if open[key] then SetVehicleDoorOpen(e, door, false, true) else SetVehicleDoorShut(e, door, true) end
        end
    end

    SetVehicleEngineOn(e, pose.engine == true, true, true)
    if pose.lights == 'on' or pose.lights == 'full' then
        SetVehicleLights(e, 2)
        SetVehicleFullbeam(e, pose.lights == 'full')
    else
        SetVehicleFullbeam(e, false)
        SetVehicleLights(e, 1)
    end
    SetVehicleInteriorlight(e, pose.interior == true)

    if IsVehicleAConvertible(e, false) then
        if pose.roof then LowerConvertibleRoof(e, true) else RaiseConvertibleRoof(e, true) end
    end

    state.steer = STEER[pose.steer] or 0.0
    SetVehicleSteeringAngle(e, state.steer)
end

-- ------------------------------------------------------------------ camera

---Everything shots.lua needs to compute camera positions in entity space.
function Scene.context()
    if not state.entity or not DoesEntityExist(state.entity) then return nil end
    return {
        entity = state.entity, type = state.type,
        min = state.min, max = state.max, center = state.center, radius = state.radius,
        fov = state.fov,
    }
end

---Entity-local position of a named bone, or nil if the model doesn't have it.
function Scene.boneLocal(name)
    local e = state.entity
    if not e then return nil end
    local idx = GetEntityBoneIndexByName(e, name)
    if idx == -1 then return nil end
    local w = GetWorldPositionOfEntityBone(e, idx)
    return GetOffsetFromEntityGivenWorldCoords(e, w.x, w.y, w.z)
end

function Scene.setLens(fov)
    state.fov = tonumber(fov) or DEFAULT_FOV
    if state.cam then SetCamFov(state.cam, state.fov) end
end

function Scene.setDof(on)
    state.dof = on == true
    if state.cam and not state.dof then SetCamUseShallowDofMode(state.cam, false) end
end

function Scene.setShake(amount)
    if not state.cam then return end
    amount = tonumber(amount) or 0
    if amount > 0 then ShakeCam(state.cam, 'HAND_SHAKE', amount) else StopCamShaking(state.cam, true) end
end

---Points the camera using entity-local positions. Keeps it above the ground
---(or the studio floor) and focuses depth of field on the target.
function Scene.look(camLocal, targetLocal)
    local e, cam = state.entity, state.cam
    if not e or not cam or not DoesEntityExist(e) then return false end
    local pos = GetOffsetFromEntityInWorldCoords(e, camLocal.x, camLocal.y, camLocal.z)
    local target = GetOffsetFromEntityInWorldCoords(e, targetLocal.x, targetLocal.y, targetLocal.z)

    local minZ
    if state.green then
        minZ = state.floorZ + 0.12
    else
        local ok, gz = GetGroundZFor_3dCoord(pos.x, pos.y, pos.z + 1.0, false)
        if ok then minZ = gz + 0.15 end
    end
    if minZ and pos.z < minZ then pos = vector3(pos.x, pos.y, minZ) end

    SetCamCoord(cam, pos.x, pos.y, pos.z)
    PointCamAtCoord(cam, target.x, target.y, target.z)
    if state.dof then
        local d = #(target - pos)
        SetCamUseShallowDofMode(cam, true)
        SetCamNearDof(cam, math.max(0.05, d * 0.55))
        SetCamFarDof(cam, d * 1.6)
        SetCamDofStrength(cam, 1.0)
    end
    return true
end

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    Scene.leave()
end)

-- ===================================================================== Shots
-- Camera angles (photos) and moves (videos). Everything is in the subject's
-- local space, relative to its bounding box, and handed to Scene.look.

ImageMaker = ImageMaker or {}
local Scene = ImageMaker.scene
local Shots = {}
ImageMaker.shots = Shots

local rad, sin, cos, sqrt = math.rad, math.sin, math.cos, math.sqrt

local function smooth(x)
    x = math.max(0.0, math.min(1.0, x))
    return x * x * (3 - 2 * x)
end
local function lerp(a, b, t) return a + (b - a) * t end
local function wrapPi(a) return (a + math.pi) % (2 * math.pi) - math.pi end

local function norm(v)
    local len = #v
    if len < 0.0001 then return vector3(0.0, 1.0, 0.0) end
    return v / len
end

---Distance that fits the subject's bounding sphere in frame.
local function fit(ctx, zoom)
    return ctx.radius / sin(rad(ctx.fov / 2)) * 1.05 / (zoom or 1.0)
end

---Point on a sphere around the subject centre. heading 0 = front, -90 = driver side.
local function sph(ctx, headingDeg, pitchDeg, dist)
    local h, p = rad(headingDeg), rad(pitchDeg)
    return ctx.center + vector3(dist * cos(p) * sin(h), dist * cos(p) * cos(h), dist * sin(p))
end

local function height(ctx) return ctx.max.z - ctx.min.z end

-- ------------------------------------------------------------------ angles

Shots.angles = {
    { id = 'current', label = 'Current framing (Frame camera)' },
    { id = 'default', label = 'Default (library)' },
    { id = 'hero', label = 'Hero (low front 3/4)' },
    { id = 'three_quarter_front', label = 'Front 3/4' },
    { id = 'front', label = 'Front' },
    { id = 'side', label = 'Side' },
    { id = 'low_side', label = 'Low side' },
    { id = 'three_quarter_rear', label = 'Rear 3/4' },
    { id = 'rear_hero', label = 'Hero rear (low)' },
    { id = 'rear', label = 'Rear' },
    { id = 'top', label = 'Top down' },
    { id = 'wheel', label = 'Wheel close-up' },
    { id = 'interior', label = 'Interior / cockpit' },
    { id = 'engine', label = 'Engine bay (open the hood)' },
    { id = 'trunk', label = 'Trunk (open it)' },
    { id = 'portrait', label = 'Ped headshot' },
}
Shots.angleLabel = {}
for _, a in ipairs(Shots.angles) do Shots.angleLabel[a.id] = a.label end

local ORBIT = {
    default = { veh = { 0, 25 }, ped = { 0, 8 }, obj = { 0, 20 } },
    hero = { -35, 2, 0.85 },
    three_quarter_front = { -40, 14 },
    front = { 0, 8 },
    side = { -90, 6 },
    low_side = { -90, 1, 0.9 },
    three_quarter_rear = { -140, 14 },
    rear_hero = { -150, 2, 0.85 },
    rear = { 180, 8 },
    top = { 0, 80 },
}

local function orbitShot(ctx, preset, zoom)
    return sph(ctx, preset[1], preset[2], fit(ctx, zoom) * (preset[3] or 1.0)), ctx.center
end

local special = {}

function special.wheel(ctx, zoom)
    local wheel = Scene.boneLocal('wheel_lf') or vector3(ctx.min.x, ctx.max.y * 0.6, ctx.min.z + 0.35)
    local d = (1.1 + ctx.radius * 0.1) / zoom
    return wheel + norm(vector3(-1.0, 0.55, 0.12)) * d, wheel
end

function special.interior(ctx, zoom)
    local seat = Scene.boneLocal('seat_dside_f') or vector3(ctx.center.x - 0.35, ctx.center.y, ctx.min.z + 0.5)
    local cam = vector3(seat.x + 0.3, seat.y - 0.45 / zoom, seat.z + 0.72)
    return cam, vector3(0.0, seat.y + 1.4, seat.z + 0.5)
end

function special.engine(ctx, zoom)
    local bay = vector3(0.0, ctx.max.y * 0.55, ctx.center.z + height(ctx) * 0.1)
    return vector3(0.0, ctx.max.y + 0.7 / zoom, ctx.max.z + 0.9 / zoom), bay
end

function special.trunk(ctx, zoom)
    local boot = vector3(0.0, ctx.min.y * 0.6, ctx.center.z + height(ctx) * 0.05)
    return vector3(0.0, ctx.min.y - 0.9 / zoom, ctx.max.z + 0.8 / zoom), boot
end

function special.portrait(ctx, zoom)
    local head = Scene.boneLocal('SKEL_Head')
    if not head then
        local e = ctx.entity
        local w = GetPedBoneCoords(e, 31086, 0.0, 0.0, 0.0)
        head = GetOffsetFromEntityGivenWorldCoords(e, w.x, w.y, w.z)
    end
    return vector3(head.x, head.y + 1.1 / zoom, head.z), vector3(head.x, head.y, head.z - 0.08)
end

local VEHICLE_ONLY = { wheel = true, interior = true, engine = true, trunk = true }

---@return vector3|nil camLocal, vector3 targetLocal
function Shots.angle(id, ctx, zoom)
    if not ctx then return nil end
    zoom = (type(zoom) == 'number' and zoom > 0) and zoom or 1.0
    if VEHICLE_ONLY[id] and ctx.type ~= 'veh' then id = 'front' end
    if id == 'portrait' and ctx.type ~= 'ped' then id = 'front' end
    if special[id] then return special[id](ctx, zoom) end
    local preset = ORBIT[id] or ORBIT.default
    if id == 'default' or not ORBIT[id] then preset = ORBIT.default[ctx.type] or ORBIT.default.obj end
    return orbitShot(ctx, preset, zoom)
end

-- ------------------------------------------------------------------- moves

Shots.moves = {
    { id = 'orbit', label = 'Orbit' },
    { id = 'details', label = 'Detail fly-around (vehicles)' },
    { id = 'hero', label = 'Hero push-in' },
    { id = 'flyby', label = 'Side fly-by' },
    { id = 'crane', label = 'Crane up' },
    { id = 'reveal', label = 'Detail reveal' },
    { id = 'low_orbit', label = 'Low orbit' },
    { id = 'topdown', label = 'Top-down spin' },
    { id = 'montage', label = 'Cinematic montage (cuts)' },
}
Shots.moveLabel = {}
for _, m in ipairs(Shots.moves) do Shots.moveLabel[m.id] = m.label end

-- Camera positions as cylinder coords around the centre, so moving between
-- shots arcs around the subject instead of cutting through it.
local function toCyl(ctx, v, nearTh)
    local d = v - ctx.center
    local th = math.atan(d.x, d.y)
    if nearTh then th = nearTh + wrapPi(th - nearTh) end
    return { th = th, r = sqrt(d.x * d.x + d.y * d.y), z = v.z }
end

local function fromCyl(ctx, k)
    return vector3(ctx.center.x + k.r * sin(k.th), ctx.center.y + k.r * cos(k.th), k.z)
end

local function cylLerp(ctx, a, b, u)
    return fromCyl(ctx, { th = lerp(a.th, b.th, u), r = lerp(a.r, b.r, u), z = lerp(a.z, b.z, u) })
end

-- Detail shot looking at a bone from outside the vehicle.
local function detailShot(ctx, name, bone, dist)
    local dir
    if name == 'steeringwheel' then
        dir = norm(vector3(-1.0, -0.15, 0.35)) -- in through the driver's window
    elseif name:find('^wheel_') then
        dir = norm(vector3(bone.x < ctx.center.x and -1.0 or 1.0, bone.y < ctx.center.y and -0.45 or 0.45, 0.2))
    else
        local d = bone - ctx.center
        dir = norm(norm(vector3(d.x, d.y, 0.0)) + vector3(0.0, 0.0, 0.35))
    end
    return { cam = bone + dir * dist, target = bone }
end

local TOUR_BONES = {
    'headlight_l', 'headlight_r', 'bumper_f', 'bonnet', 'steeringwheel',
    'wheel_lf', 'wheel_rf', 'door_dside_f', 'door_pside_f', 'wheel_lm1', 'wheel_rm1',
    'wheel_lr', 'wheel_rr', 'taillight_l', 'taillight_r', 'bumper_r', 'boot',
    'exhaust', 'exhaust_2', 'spoiler', 'rotor_main', 'prop_1',
}
local TOUR_HOLD, TOUR_PUSH, TOUR_MIN_SHOT = 0.35, 0.12, 1.3

local function planTour(ctx, opts)
    if ctx.type ~= 'veh' then return nil end
    local dist = (0.9 + ctx.radius * 0.25) / opts.zoom
    local shots = {}
    for _, name in ipairs(TOUR_BONES) do
        local bone = Scene.boneLocal(name)
        if bone then
            local duplicate = false
            for _, s in ipairs(shots) do
                if #(s.target - bone) < 0.5 then duplicate = true break end
            end
            if not duplicate then shots[#shots + 1] = detailShot(ctx, name, bone, dist) end
        end
    end
    if #shots < 2 then return nil end

    local start = toCyl(ctx, sph(ctx, -40, opts.pitch, fit(ctx, opts.zoom)))
    for _, s in ipairs(shots) do
        s.cyl = toCyl(ctx, s.cam)
        s.order = (s.cyl.th - start.th) % (2 * math.pi)
    end
    table.sort(shots, function(a, b) return a.order < b.order end)

    local maxShots = math.max(2, math.floor((opts.seconds - 2.0) / TOUR_MIN_SHOT))
    if #shots > maxShots then
        local picked = {}
        for i = 1, maxShots do picked[i] = shots[math.floor((i - 1) * #shots / maxShots) + 1] end
        shots = picked
    end

    local keys = { { cyl = start, target = ctx.center } }
    for _, s in ipairs(shots) do
        s.cyl.th = start.th + s.order
        keys[#keys + 1] = { cyl = s.cyl, target = s.target }
    end
    keys[#keys + 1] = { cyl = { th = start.th + 2 * math.pi, r = start.r, z = start.z }, target = ctx.center }
    for _, k in ipairs(keys) do
        k.pushed = toCyl(ctx, lerp(fromCyl(ctx, k.cyl), k.target, TOUR_PUSH), k.cyl.th)
    end

    return function(t)
        local legs = #keys - 1
        local x = math.max(0.0, math.min(t, 1.0)) * legs
        local i = math.min(math.floor(x), legs - 1) + 1
        local f = x - (i - 1)
        local a, b = keys[i], keys[i + 1]
        if f < TOUR_HOLD then
            return lerp(fromCyl(ctx, a.cyl), a.target, TOUR_PUSH * smooth(f / TOUR_HOLD)), a.target
        end
        local u = smooth((f - TOUR_HOLD) / (1 - TOUR_HOLD))
        return cylLerp(ctx, a.pushed, b.cyl, u), lerp(a.target, b.target, u)
    end
end

local builders = {}

function builders.orbit(ctx, o)
    local d = fit(ctx, o.zoom)
    return function(t) return sph(ctx, -40 + 360 * t, o.pitch, d), ctx.center end
end

function builders.hero(ctx, o)
    local d = fit(ctx, o.zoom)
    local lowered = ctx.center - vector3(0.0, 0.0, height(ctx) * 0.1)
    return function(t)
        local u = smooth(t)
        return sph(ctx, lerp(-40, -22, u), lerp(1.5, 7, u), lerp(1.6, 0.8, u) * d),
            lerp(lowered, ctx.center + vector3(0.0, ctx.max.y * 0.15, 0.0), u)
    end
end

function builders.flyby(ctx, o)
    local side = ctx.min.x - (0.9 + ctx.radius * 0.35) / o.zoom
    local len = ctx.radius * 1.3
    local z = ctx.center.z - height(ctx) * 0.15
    return function(t)
        local u = lerp(t, smooth(t), 0.35)
        local y = lerp(ctx.max.y + len, ctx.min.y - len, u)
        return vector3(side, y, z), vector3(ctx.center.x, y * 0.35, ctx.center.z)
    end
end

function builders.crane(ctx, o)
    local d = fit(ctx, o.zoom)
    return function(t)
        local u = smooth(t)
        return sph(ctx, lerp(-25, 25, u), lerp(0, 75, u), lerp(0.9, 1.15, u) * d), ctx.center
    end
end

function builders.reveal(ctx, o)
    local bone = (ctx.type == 'veh' and (Scene.boneLocal('headlight_l') or Scene.boneLocal('bumper_f')))
        or (ctx.center + vector3(0.0, ctx.max.y * 0.8, 0.0))
    local first = detailShot(ctx, 'headlight_l', bone, (0.8 + ctx.radius * 0.15) / o.zoom)
    local a = toCyl(ctx, first.cam)
    local b = toCyl(ctx, sph(ctx, -40, o.pitch, fit(ctx, o.zoom)), a.th)
    if b.th > a.th then b.th = b.th - 2 * math.pi end -- pull back the long way round
    return function(t)
        local u = smooth(t)
        return cylLerp(ctx, a, b, u), lerp(first.target, ctx.center, u)
    end
end

function builders.low_orbit(ctx, o)
    local d = fit(ctx, o.zoom) * 0.75
    return function(t) return sph(ctx, lerp(-70, 110, smooth(t)), -4, d), ctx.center end
end

function builders.topdown(ctx, o)
    local d = fit(ctx, o.zoom)
    return function(t) return sph(ctx, 360 * t, 86, lerp(1.15, 0.9, smooth(t)) * d), ctx.center end
end

function builders.montage(ctx, o)
    local cuts = {
        { to = 0.30, move = builders.hero(ctx, o) },
        { to = 0.55, move = builders.flyby(ctx, o) },
        { to = 0.80, move = builders.low_orbit(ctx, o) },
        { to = 1.00, move = builders.crane(ctx, o) },
    }
    return function(t)
        local from = 0.0
        for _, cut in ipairs(cuts) do
            if t <= cut.to then return cut.move((t - from) / (cut.to - from)) end
            from = cut.to
        end
        return cuts[#cuts].move(1.0)
    end
end

---Builds a camera move. Returns eval(t) -> camLocal, targetLocal (t in 0..1),
---and the move actually used (details falls back to orbit for non-vehicles).
---@param opts table { seconds: number, pitch: number, zoom: number }
function Shots.move(id, ctx, opts)
    if not ctx then return nil end
    opts = {
        seconds = tonumber(opts.seconds) or 8,
        pitch = tonumber(opts.pitch) or 12,
        zoom = (tonumber(opts.zoom) or 1.0) > 0 and (tonumber(opts.zoom) or 1.0) or 1.0,
    }
    if id == 'details' then
        local tour = planTour(ctx, opts)
        if tour then return tour, 'details' end
        id = 'orbit'
    end
    local build = builders[id] or builders.orbit
    return build(ctx, opts), builders[id] and id or 'orbit'
end
