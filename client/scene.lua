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
