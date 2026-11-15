RegisterCommand('image_maker', function(source)
    if source == 0 then return end -- console has no player to gate/open a UI for

    if not exports['kora_core']:hasPermission(source, 'admin') then
        Kora.notify.send(source, { title = 'Image Maker', message = 'Admin permission required.', type = 'error' })
        return
    end

    TriggerClientEvent('kora_image_maker:client:open', source)
end, false)

TriggerClientEvent('chat:addSuggestion', -1, '/image_maker', 'Open the image maker tool (admin only)')

-- Client-side failures (model/entity/capture) have no server trace by default --
-- mirrored here so they show up without needing the player's own F8 console.
-- One-line client diagnostics (e.g. measured subject size), capped and admin-only.
RegisterNetEvent('kora_image_maker:server:diag', function(message)
    local src = source
    if type(message) ~= 'string' or not exports['kora_core']:hasPermission(src, 'admin') then return end
    Kora.logging.info('client.diag', 'Client diagnostic', { playerId = src, message = message:sub(1, 300) })
end)

RegisterNetEvent('kora_image_maker:server:clientError', function(tag, ...)
    local details = {}
    for index = 1, select('#', ...) do details[index] = tostring((select(index, ...))):sub(1, 100) end
    Kora.logging.warn('client.error_reported', 'Client reported an error', {
        playerId = source,
        tag = tostring(tag):sub(1, 200),
        details = table.concat(details, ' '),
    })
end)
