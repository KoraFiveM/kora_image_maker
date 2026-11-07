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
