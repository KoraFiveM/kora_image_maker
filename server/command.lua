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
RegisterNetEvent('kora_image_maker:server:clientError', function(tag, ...)
    print(('[kora_image_maker] client error from %s: %s'):format(GetPlayerName(source) or source, tag), ...)
end)
