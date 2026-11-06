fx_version "cerulean"
lua54 'yes'

game "gta5"

name 'kora_image_maker'
author 'Jamie'
description 'Green-room photo/video capture with Discord posting'

dependency 'kora_lib'
dependency 'kora_core'

shared_scripts {
  '@kora_lib/init.lua',
}

-- Listed explicitly: server/webhook.lua, package.json and node_modules are
-- leftovers from the old image-js pipeline and must not load.
client_scripts {
  'client/greenRoom.lua',
  'client/capture.lua',
  'client/ui.lua',
}

server_scripts {
  'server/command.lua',
  'server/server.js',
}

ui_page 'web/index.html'

-- images/ (~310 MB library) is deliberately not in files: listing it made
-- every client download all of it on join. Add it back only if another
-- resource needs to load those images over nui://.
files {
  'web/index.html',
  'web/app.js',
}
