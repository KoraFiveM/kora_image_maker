-- Green room: a big unlit green box drawn high above the ocean, a scripted
-- camera, and one display entity framed from its model bounds.

ImageMaker = ImageMaker or {}
local Room = {}
ImageMaker.room = Room

local ROOM = vec3(-3438.14, 7712.19, 2694.69)
local HALF = 250.0
local HEIGHT = 500.0
local FLOOR = ROOM.z - 1.0
local FOV = 30.0
local HEAD_BONE = 31086

-- heading: degrees around the entity (0 = its front, +90 = its right side).
-- pitch: degrees above the horizontal.
local ANGLES = {
    default = { veh = { 0, 25 }, ped = { 0, 8 }, obj = { 0, 20 } },
    front = { 0, 8 },
    three_quarter_front = { -40, 14 },
    side = { -90, 6 },
    three_quarter_rear = { -140, 14 },
    rear = { 180, 8 },
    top = { 0, 80 },
}
Room.angleIds = { 'default', 'front', 'three_quarter_front', 'side', 'three_quarter_rear', 'rear', 'top', 'portrait' }

local state = {
    active = false,
    cam = nil,
    entity = nil,
    model = nil,
    type = nil,
    center = nil,
    radius = nil,
    returnTo = nil,
}

local function drawQuad(a, b, c, d)
    -- Both windings so every face is visible from inside and out.
    DrawPoly(a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z, 0, 255, 0, 255)
    DrawPoly(c.x, c.y, c.z, b.x, b.y, b.z, a.x, a.y, a.z, 0, 255, 0, 255)
    DrawPoly(c.x, c.y, c.z, d.x, d.y, d.z, a.x, a.y, a.z, 0, 255, 0, 255)
    DrawPoly(a.x, a.y, a.z, d.x, d.y, d.z, c.x, c.y, c.z, 0, 255, 0, 255)
end

local corners = {
    vec3(ROOM.x - HALF, ROOM.y - HALF, FLOOR),
    vec3(ROOM.x + HALF, ROOM.y - HALF, FLOOR),
    vec3(ROOM.x + HALF, ROOM.y + HALF, FLOOR),
    vec3(ROOM.x - HALF, ROOM.y + HALF, FLOOR),
}
local up = vec3(0.0, 0.0, HEIGHT)

local function drawRoom()
    drawQuad(corners[1], corners[2], corners[3], corners[4])
    drawQuad(corners[1] + up, corners[2] + up, corners[3] + up, corners[4] + up)
    for i = 1, 4 do
        local a, b = corners[i], corners[i % 4 + 1]
        drawQuad(a, b, b + up, a + up)
    end
end

local function removeEntity()
    if state.entity and DoesEntityExist(state.entity) then Kora.entities.remove(state.entity) end
    state.entity, state.model, state.type, state.center, state.radius = nil, nil, nil, nil, nil
end

function Room.isActive() return state.active end
function Room.current() return state.entity, state.model, state.type end

function Room.enter()
    if state.active then return true end
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, false) then return false, 'Get out of your vehicle first.' end

    state.returnTo = { coords = GetEntityCoords(ped), heading = GetEntityHeading(ped) }
    state.active = true

    -- Park the player, invisible and frozen, inside the room out of frame.
    SetEntityVisible(ped, false, false)
    FreezeEntityPosition(ped, true)
    SetEntityCoords(ped, ROOM.x, ROOM.y - 60.0, ROOM.z, false, false, false, false)
    SetFocusPosAndVel(ROOM.x, ROOM.y, ROOM.z, 0.0, 0.0, 0.0)
    SetOverrideWeather('EXTRASUNNY')

    state.cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    SetCamFov(state.cam, FOV)
    SetCamCoord(state.cam, ROOM.x, ROOM.y + 6.0, ROOM.z + 1.5)
    PointCamAtCoord(state.cam, ROOM.x, ROOM.y, ROOM.z)
    SetCamActive(state.cam, true)
    RenderScriptCams(true, false, 0, true, true)

    CreateThread(function()
        while state.active do
            drawRoom()
            HideHudAndRadarThisFrame()
            NetworkOverrideClockTime(10, 0, 0)
            Wait(0)
        end
    end)
    return true
end

function Room.leave()
    if not state.active then return end
    state.active = false
    removeEntity()

    RenderScriptCams(false, false, 0, true, true)
    if state.cam and DoesCamExist(state.cam) then DestroyCam(state.cam, false) end
    state.cam = nil
    ClearFocus()
    ClearOverrideWeather()
    NetworkClearClockTimeOverride()

    local ped = PlayerPedId()
    local back = state.returnTo
    state.returnTo = nil
    if back then
        SetEntityCoords(ped, back.coords.x, back.coords.y, back.coords.z, false, false, false, false)
        SetEntityHeading(ped, back.heading)
    end
    FreezeEntityPosition(ped, false)
    SetEntityVisible(ped, true, false)
end

---@return string|nil type 'veh' | 'ped' | 'obj', or nil if the model doesn't exist
function Room.modelType(model)
    local hash = type(model) == 'number' and model or joaat(model)
    if not IsModelInCdimage(hash) or not IsModelValid(hash) then return nil end
    if IsModelAVehicle(hash) then return 'veh' end
    if IsModelAPed(hash) then return 'ped' end
    return 'obj'
end

---@param opts? { colour?: integer }
---@return integer|false entity, string? typeOrError
function Room.spawn(model, opts)
    if not state.active then return false, 'Green room is not active.' end
    opts = opts or {}
    local entityType = Room.modelType(model)
    if not entityType then return false, ('Unknown model "%s".'):format(model) end

    removeEntity()
    local entity, err = Kora.entities.create(model, ROOM, { preset = 'static', heading = 0.0 })
    if not entity then return false, ('Could not spawn %s: %s'):format(model, tostring(err)) end

    if entityType == 'veh' then
        if opts.colour then SetVehicleColours(entity, opts.colour, opts.colour) end
        SetVehicleDirtLevel(entity, 0.0)
        SetVehicleEngineOn(entity, false, true, true)
    elseif entityType == 'ped' then
        SetPedDefaultComponentVariation(entity)
    end

    local min, max = GetModelDimensions(GetEntityModel(entity))
    state.entity, state.model, state.type = entity, model, entityType
    state.center = (min + max) / 2
    state.radius = math.max(#(max - min) / 2, 0.15)

    -- Give high-detail textures and LODs a moment to stream in before capturing.
    Wait(600)
    return entity, entityType
end

local function setCam(pos, target)
    SetCamCoord(state.cam, pos.x, pos.y, pos.z)
    PointCamAtCoord(state.cam, target.x, target.y, target.z)
end

---Frames the current entity from a spherical position in its local space.
function Room.aim(headingDeg, pitchDeg, zoom)
    local e = state.entity
    if not e or not DoesEntityExist(e) or not state.cam then return false end
    zoom = (type(zoom) == 'number' and zoom > 0) and zoom or 1.0

    local dist = state.radius / math.sin(math.rad(FOV / 2)) * 1.05 / zoom
    local h, p = math.rad(headingDeg), math.rad(pitchDeg)
    local c = state.center
    local pos = GetOffsetFromEntityInWorldCoords(e,
        c.x + dist * math.cos(p) * math.sin(h),
        c.y + dist * math.cos(p) * math.cos(h),
        c.z + dist * math.sin(p))
    setCam(pos, GetOffsetFromEntityInWorldCoords(e, c.x, c.y, c.z))
    return true
end

---Head-and-shoulders shot for peds; other entities fall back to `front`.
local function aimPortrait(zoom)
    local e = state.entity
    if state.type ~= 'ped' then return Room.aim(ANGLES.front[1], ANGLES.front[2], zoom) end
    zoom = (type(zoom) == 'number' and zoom > 0) and zoom or 1.0
    local head = GetPedBoneCoords(e, HEAD_BONE, 0.0, 0.0, 0.0)
    local localHead = GetOffsetFromEntityGivenWorldCoords(e, head.x, head.y, head.z)
    local target = GetOffsetFromEntityInWorldCoords(e, localHead.x, localHead.y, localHead.z - 0.08)
    local pos = GetOffsetFromEntityInWorldCoords(e, localHead.x, localHead.y + 1.1 / zoom, localHead.z)
    setCam(pos, target)
    return true
end

---@return boolean ok
function Room.aimPreset(angle, zoom)
    if angle == 'portrait' then return aimPortrait(zoom) end
    local preset = ANGLES[angle] or ANGLES.default
    if angle == 'default' or not ANGLES[angle] then preset = ANGLES.default[state.type or 'obj'] end
    return Room.aim(preset[1], preset[2], zoom)
end

---Rotates the entity itself (turntable). Camera stays where it is.
function Room.setEntityHeading(deg)
    if state.entity and DoesEntityExist(state.entity) then SetEntityHeading(state.entity, deg % 360.0) end
end

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    Room.leave()
end)
