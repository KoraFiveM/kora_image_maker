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
