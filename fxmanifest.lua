fx_version "cerulean"
games { "rdr3" }
rdr3_warning "I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships."
lua54 "yes"
author "BCC Scripts"

shared_scripts {
    'config.lua',
    'locale.lua',
    'languages/*.lua'
}

-- Each file is listed once: a file named here and also matched by a glob loads twice.
client_scripts {
    'client/feather/init.lua',
    'client/feather/menu_v2.lua',
    'client/helpers/*.lua',
    'client/services/menus/*.lua',
    'client/services/*.lua',
    'client/main.lua'
}

server_scripts {
    '@feather-mysql/lib/DB.lua',
    'server/feather/init.lua',
    'server/feather/authority.lua',
    'server/feather/economy.lua',
    'server/feather/jobs.lua',
    'server/feather/organizations.lua',
    'server/helpers/*.lua',
    'server/services/*.lua',
    'server/main.lua'
}

dependencies {
    'feather-mysql',
    'feather-core',
    'feather-character',
    'feather-notify',
    'feather-toolkit',
    'feather-menu-v2',
    'feather-jobs',
    'feather-economy',
    'feather-inventory',
    'feather-organizations',
    'feather-authority'
}

version '2.0.0'
