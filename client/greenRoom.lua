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
    fov = FOV,
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

-- Invisible collision floor so vehicles rest on their wheels: frozen in mid-air
-- the suspension hangs at full droop. Tiles of the first prop that exists,
-- top flush with the drawn floor. Containers exist in every game build.
local PLATFORM_MODELS = { 'stt_prop_stunt_bblock_huge_01', 'prop_container_01a' }
local PLATFORM_MAX_TILES = 64
local platform = {}

local function clearPlatform()
    for _, tile in ipairs(platform) do
        if DoesEntityExist(tile) then Kora.entities.remove(tile) end
    end
    platform = {}
end

---@return boolean built
local function buildPlatform(vehMin, vehMax)
    clearPlatform()
    local needW, needD = (vehMax.x - vehMin.x) + 2.0, (vehMax.y - vehMin.y) + 2.0
    local parked = vec3(ROOM.x, ROOM.y, FLOOR - 80.0)
    for _, model in ipairs(PLATFORM_MODELS) do
        if IsModelInCdimage(joaat(model)) then
            local first = Kora.entities.create(model, parked, { freeze = true, heading = 0.0 })
            if first then
                local pmin, pmax = GetModelDimensions(GetEntityModel(first))
                local w, d = pmax.x - pmin.x, pmax.y - pmin.y
                local nx, ny = math.max(1, math.ceil(needW / w)), math.max(1, math.ceil(needD / d))
                if w > 0.5 and d > 0.5 and nx * ny <= PLATFORM_MAX_TILES then
                    local tiles = { first }
                    for i = 2, nx * ny do
                        tiles[i] = Kora.entities.create(model, parked, { freeze = true, heading = 0.0 }) or nil
                    end
                    local i = 0
                    for ix = 0, nx - 1 do
                        for iy = 0, ny - 1 do
                            i = i + 1
                            local tile = tiles[i]
                            if tile then
                                SetEntityCoordsNoOffset(tile,
                                    ROOM.x + (ix - (nx - 1) / 2) * w - (pmin.x + pmax.x) / 2,
                                    ROOM.y + (iy - (ny - 1) / 2) * d - (pmin.y + pmax.y) / 2,
                                    FLOOR - pmax.z, false, false, false)
                                SetEntityHeading(tile, 0.0)
                                FreezeEntityPosition(tile, true)
                                SetEntityCollision(tile, true, true)
                                SetEntityVisible(tile, false, false)
                                platform[#platform + 1] = tile
                            end
                        end
                    end
                    return true
                end
                Kora.entities.remove(first)
            end
        end
    end
    return false
end

-- Drops the vehicle onto the platform and freezes it once the suspension settles.
local function settleVehicle(entity, min)
    if not buildPlatform(min, select(2, GetModelDimensions(GetEntityModel(entity)))) then return end
    SetEntityCoordsNoOffset(entity, ROOM.x, ROOM.y, FLOOR - min.z + 0.15, false, false, false)
    SetEntityHeading(entity, 0.0)
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
    Wait(150)
    FreezeEntityPosition(entity, true)
end

local function removeEntity()
    if state.entity and DoesEntityExist(state.entity) then Kora.entities.remove(state.entity) end
    state.entity, state.model, state.type, state.center, state.radius = nil, nil, nil, nil, nil
    clearPlatform()
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
    state.fov = FOV
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
    if entityType == 'veh' then settleVehicle(entity, min) end
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

    local dist = state.radius / math.sin(math.rad(state.fov / 2)) * 1.05 / zoom
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

function Room.setFov(fov)
    state.fov = fov or FOV
    if state.cam then SetCamFov(state.cam, state.fov) end
end

-- ------------------------------------------------------- bone fly-around

local TOUR_FOV = 40.0
local TOUR_HOLD = 0.35     -- share of each leg spent easing in on the current detail
local TOUR_PUSH = 0.12     -- how far the camera creeps toward the detail during the hold
local TOUR_MIN_SHOT = 1.3  -- seconds per detail; fewer details on short videos

-- Detail shots, if the model has the bone. Order doesn't matter: shots are
-- sorted by their angle around the vehicle so the camera sweeps one way.
local VEHICLE_BONES = {
    'headlight_l', 'headlight_r', 'bumper_f', 'bonnet', 'steeringwheel',
    'wheel_lf', 'wheel_rf', 'door_dside_f', 'door_pside_f', 'wheel_lm1', 'wheel_rm1',
    'wheel_lr', 'wheel_rr', 'taillight_l', 'taillight_r', 'bumper_r', 'boot',
    'exhaust', 'exhaust_2', 'spoiler', 'rotor_main', 'prop_1',
}

local function norm(v)
    local len = #v
    if len < 0.0001 then return vector3(0.0, 1.0, 0.0) end
    return v / len
end

local function wrapPi(a)
    return (a + math.pi) % (2 * math.pi) - math.pi
end

local function smooth(x) return x * x * (3 - 2 * x) end

local function lerp(a, b, t) return a + (b - a) * t end

-- Camera position relative to the entity centre as cylinder coords, so moving
-- between neighbouring shots arcs around the vehicle instead of cutting through it.
local function toCyl(v, nearTh)
    local d = v - state.center
    local th = math.atan(d.x, d.y)
    if nearTh then th = nearTh + wrapPi(th - nearTh) end
    return { th = th, r = math.sqrt(d.x * d.x + d.y * d.y), z = v.z }
end

local function fromCyl(k)
    local c = state.center
    return vector3(c.x + k.r * math.sin(k.th), c.y + k.r * math.cos(k.th), k.z)
end

local function detailShot(name, bone, dist)
    local dir
    if name == 'steeringwheel' then
        dir = norm(vector3(-1.0, -0.15, 0.35)) -- in through the driver's window
    elseif name:find('^wheel_') then
        dir = norm(vector3(bone.x < state.center.x and -1.0 or 1.0, bone.y < state.center.y and -0.45 or 0.45, 0.2))
    else
        local d = bone - state.center
        dir = norm(norm(vector3(d.x, d.y, 0.0)) + vector3(0.0, 0.0, 0.35))
    end
    return { cam = bone + dir * dist, target = bone }
end

---Plans a camera path from a wide front-3/4 shot through the vehicle's
---details and back. Returns nil if the current entity isn't a vehicle or has
---fewer than two usable bones.
function Room.planBoneTour(seconds, pitchDeg, zoom)
    local e = state.entity
    if not e or not DoesEntityExist(e) or state.type ~= 'veh' then return nil end
    zoom = (type(zoom) == 'number' and zoom > 0) and zoom or 1.0
    local c = state.center
    local dist = (0.9 + state.radius * 0.25) / zoom

    local shots = {}
    for _, name in ipairs(VEHICLE_BONES) do
        local idx = GetEntityBoneIndexByName(e, name)
        if idx ~= -1 then
            local w = GetWorldPositionOfEntityBone(e, idx)
            local bone = GetOffsetFromEntityGivenWorldCoords(e, w.x, w.y, w.z)
            local duplicate = false
            for _, shot in ipairs(shots) do
                if #(shot.target - bone) < 0.5 then duplicate = true break end
            end
            if not duplicate then shots[#shots + 1] = detailShot(name, bone, dist) end
        end
    end
    if #shots < 2 then return nil end

    -- Wide establishing shot, framed like Room.aim at the tour FOV.
    local wideDist = state.radius / math.sin(math.rad(TOUR_FOV / 2)) * 1.05 / zoom
    local h, p = math.rad(-40.0), math.rad(pitchDeg or 12.0)
    local wideCam = vector3(c.x + wideDist * math.cos(p) * math.sin(h),
        c.y + wideDist * math.cos(p) * math.cos(h), c.z + wideDist * math.sin(p))
    local start = toCyl(wideCam)

    for _, shot in ipairs(shots) do
        shot.cyl = toCyl(shot.cam)
        shot.order = (shot.cyl.th - start.th) % (2 * math.pi)
    end
    table.sort(shots, function(a, b) return a.order < b.order end)

    local maxShots = math.max(2, math.floor((seconds - 2.0) / TOUR_MIN_SHOT))
    if #shots > maxShots then
        local picked = {}
        for i = 1, maxShots do picked[i] = shots[math.floor((i - 1) * #shots / maxShots) + 1] end
        shots = picked
    end

    local keys = { { cyl = start, target = c } }
    for _, shot in ipairs(shots) do
        shot.cyl.th = start.th + shot.order -- unwrapped, always increasing
        keys[#keys + 1] = { cyl = shot.cyl, target = shot.target }
    end
    keys[#keys + 1] = { cyl = { th = start.th + 2 * math.pi, r = start.r, z = start.z }, target = c }

    -- Where each key's push-in ends, which is where its transition starts.
    for _, key in ipairs(keys) do
        key.pushed = toCyl(lerp(fromCyl(key.cyl), key.target, TOUR_PUSH), key.cyl.th)
    end
    return { keys = keys }
end

---Positions the camera at progress t (0..1) along a planned tour.
function Room.tourAt(plan, t)
    local e = state.entity
    if not plan or not e or not DoesEntityExist(e) or not state.cam then return false end
    if state.fov ~= TOUR_FOV then Room.setFov(TOUR_FOV) end

    local keys = plan.keys
    local legs = #keys - 1
    local x = math.max(0.0, math.min(t, 1.0)) * legs
    local i = math.min(math.floor(x), legs - 1) + 1
    local f = x - (i - 1)
    local a, b = keys[i], keys[i + 1]

    local cam, target
    if f < TOUR_HOLD then
        cam = lerp(fromCyl(a.cyl), a.target, TOUR_PUSH * smooth(f / TOUR_HOLD))
        target = a.target
    else
        local u = smooth((f - TOUR_HOLD) / (1 - TOUR_HOLD))
        cam = fromCyl({ th = lerp(a.pushed.th, b.cyl.th, u), r = lerp(a.pushed.r, b.cyl.r, u), z = lerp(a.pushed.z, b.cyl.z, u) })
        target = lerp(a.target, b.target, u)
    end
    setCam(GetOffsetFromEntityInWorldCoords(e, cam.x, cam.y, cam.z),
        GetOffsetFromEntityInWorldCoords(e, target.x, target.y, target.z))
    return true
end

function Room.setEntityHeading(deg)
    if state.entity and DoesEntityExist(state.entity) then SetEntityHeading(state.entity, deg % 360.0) end
end

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    Room.leave()
end)
