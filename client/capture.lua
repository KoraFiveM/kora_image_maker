-- Bridge to the capture page (web/app.js). Each job has an id; the page posts
-- `result` when done and the server confirms the saved file with
-- `kora_image_maker:client:saved`. A job settles once both have arrived (or
-- just the page result for jobs that don't save anything). Discord posting is
-- done by the server after saving: Discord rejects webhook posts made from the
-- in-game browser (403, code 40333).

ImageMaker = ImageMaker or {}
local Capture = {}
ImageMaker.capture = Capture

local LATENT_BPS = 2 * 1024 * 1024
local CHUNK_ACK_TIMEOUT = 30000
local jobs = {}
local seq = 0

local function newJob(meta, opts)
    seq = seq + 1
    local id = ('%d_%d'):format(GetGameTimer(), seq)
    local job = { id = id, meta = meta, saves = opts.saves ~= false, p = promise.new() }
    jobs[id] = job
    SetTimeout(opts.timeout or 180000, function()
        if jobs[id] then
            jobs[id] = nil
            job.p:resolve({ ok = false, error = 'Timed out waiting for the capture.' })
        end
    end)
    return job
end

local function settle(job)
    if not jobs[job.id] then return end
    local nui, server = job.nui, job.server
    if not nui then return end
    if nui.ok and job.saves and not server then return end

    jobs[job.id] = nil
    local result = {
        ok = nui.ok and (not job.saves or server.ok) or false,
        error = nui.error,
        width = nui.width,
        height = nui.height,
        bytes = nui.bytes,
        discord = server and server.discord or nil,
    }
    if nui.ok and job.saves then
        if server.ok then result.path = server.path else result.error = server.error end
    end
    job.p:resolve(result)
end

local function send(action, payload)
    payload.app = 'kora_image_maker'
    payload.action = action
    SendNUIMessage(payload)
end

local function extFor(mime)
    if type(mime) ~= 'string' then return nil end
    mime = mime:match('^[^;]+')
    return ({ ['image/png'] = 'png', ['image/jpeg'] = 'jpg', ['video/webm'] = 'webm', ['video/mp4'] = 'mp4' })[mime]
end

---@param meta table server naming info: { kind = 'entity'|'scene'|'video', type?, model?, angle?, motion? }
---@param opts table capture options for app.js
---@param discord? { url: string, content: string } posted by the server once saved
function Capture.photo(meta, opts, discord)
    local job = newJob(meta, {})
    job.discord = discord
    send('photo', { id = job.id, opts = opts })
    return Citizen.Await(job.p)
end

---Starts recording; returns a job handle to pass to stopVideo, or nil + error.
function Capture.startVideo(meta, opts)
    local job = newJob(meta, { timeout = 600000 })
    job.started = promise.new()
    send('recordStart', { id = job.id, opts = opts })
    local ack = Citizen.Await(job.started)
    job.started = nil
    if not ack.ok then
        jobs[job.id] = nil
        return nil, ack.error or 'Recording failed to start.'
    end
    return job
end

function Capture.stopVideo(job, discord)
    job.discord = discord
    send('recordStop', { id = job.id })
    return Citizen.Await(job.p)
end

function Capture.cancelVideo(job)
    jobs[job.id] = nil
    send('cancelRecording', { id = job.id })
end

local discordRequests = {}

local function discordRequest(event, timeout, ...)
    seq = seq + 1
    local id = ('d%d_%d'):format(GetGameTimer(), seq)
    local p = promise.new()
    discordRequests[id] = p
    SetTimeout(timeout, function()
        if discordRequests[id] == p then
            discordRequests[id] = nil
            p:resolve({ ok = false, error = 'Timed out waiting for Discord.' })
        end
    end)
    TriggerServerEvent(event, id, ...)
    return Citizen.Await(p)
end

---Re-posts a file the server already saved (relative path from a result).
function Capture.repost(path, discord)
    return discordRequest('kora_image_maker:server:repost', 90000, path, discord)
end

function Capture.testWebhook(url, content)
    return discordRequest('kora_image_maker:server:testWebhook', 30000, url, content)
end

RegisterNetEvent('kora_image_maker:client:discordResult', function(id, ok, err)
    local p = discordRequests[id]
    if not p then return end
    discordRequests[id] = nil
    p:resolve({ ok = ok == true, error = err })
end)

RegisterNUICallback('result', function(data, cb)
    cb({})
    local job = type(data) == 'table' and jobs[data.id]
    if not job then return end
    job.nui = data
    settle(job)
end)

RegisterNUICallback('recordStarted', function(data, cb)
    cb({})
    local job = type(data) == 'table' and jobs[data.id]
    if job and job.started then job.started:resolve(data) end
end)

RegisterNUICallback('uploadBegin', function(data, cb)
    local job = type(data) == 'table' and jobs[data.id]
    if not job or not job.saves then return cb({ ok = false, error = 'Unknown capture.' }) end
    local ext = extFor(data.mime)
    if not ext then return cb({ ok = false, error = ('Unsupported format %s.'):format(tostring(data.mime)) }) end
    local n = math.tointeger(tonumber(data.n))
    if not n or n < 1 then return cb({ ok = false, error = 'Bad chunk count.' }) end
    TriggerServerEvent('kora_image_maker:server:begin', job.id, job.meta, n, tonumber(data.bytes) or 0, ext, job.discord)
    cb({ ok = true })
end)

-- One chunk in flight at a time: the page waits on this callback, which waits
-- for the server's ack. Queueing every chunk at once overflowed FiveM's latent
-- event buffer and got the player dropped ("latent event packet overflow").
local acks = {}

RegisterNUICallback('uploadChunk', function(data, cb)
    local job = type(data) == 'table' and jobs[data.id]
    local i = job and math.tointeger(tonumber(data.i))
    if not i or type(data.data) ~= 'string' then return cb({ ok = false, error = 'Bad chunk.' }) end

    local key = ('%s:%d'):format(job.id, i)
    local p = promise.new()
    acks[key] = p
    SetTimeout(CHUNK_ACK_TIMEOUT, function()
        if acks[key] == p then
            acks[key] = nil
            p:resolve(false)
        end
    end)
    TriggerLatentServerEvent('kora_image_maker:server:chunk', LATENT_BPS, job.id, i, data.data)

    if Citizen.Await(p) then return cb({ ok = true }) end
    cb({ ok = false, error = 'Server did not confirm the upload.' })
end)

RegisterNetEvent('kora_image_maker:client:chunkAck', function(id, i, ok)
    local key = ('%s:%s'):format(tostring(id), tostring(math.tointeger(i) or i))
    local p = acks[key]
    if not p then return end
    acks[key] = nil
    p:resolve(ok == true)
end)

RegisterNetEvent('kora_image_maker:client:saved', function(id, ok, pathOrError, discord)
    local job = jobs[id]
    if not job then return end
    job.server = ok and { ok = true, path = pathOrError, discord = discord }
        or { ok = false, error = pathOrError or 'Server failed to save.' }
    settle(job)
end)
