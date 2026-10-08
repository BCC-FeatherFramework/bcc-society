Config = {
    devMode = true,                             -- Enable/Disable Dev Mode (False on live)
    defaultlang = "en_us",                      -- Language used by the server (en_us, pl, ro)
    NotifyStyle = "right",                      -- feather-notify style used for player messages
    createSocietyCommandName = "createSociety", -- Command to create a society

    -- Society administration is a feather-authority capability (staff only).
    -- Feather Admin owners/administrators are accepted through their staff role.
    Admin = {
        allowConsole = true,
        capability = 'staff.society.manage',
        role = 'staff.society.admin',
        staffRoles = { 'staff.admin.owner', 'staff.admin.administrator' }
    },
    -- Characters holding one of these feather-jobs jobs may also administer societies.
    AllowedJobs = { 'societymanager' },

    employeeWorksAtMultiple = true,                     -- Allow employees to work at multiple societies (Can only own one regardless of this setting)
    openJobManagementMenuCommandName = "jobManagement", -- Command to open the job management menu (This is how you switch between jobs (NOTE this only applies if you enable employeeWorksAtMultiple))
    switchJobCommandName = "switchjob",                 -- Command to switch directly to a specific job
    switchJobCooldownSeconds = 30,                      -- Cooldown for the switch job command in seconds (set to 0 to disable)

    toggleOnDutyCommandName = "onDuty",       -- Command to toggle duty
    toggleOffDutyCommandName = "offDuty",     -- Command to toggle duty
    allowBlips = true,                        -- Allow blips to be shown for societies
    MaxStorageSlots = 500,                    -- Largest society storage in slots, upgrades included (feather-inventory stores up to 65535)
    toggleBlipCooldown = 10,                  -- Cooldown for toggling blips in seconds
    manageSocietyPromptKey = 0x4CC0E2FE,      -- Key to open the society management prompt
    taxesEnabled = true,                      -- Enable/Disable taxes
    taxDay = 26,                              -- Day of the month to collect taxes
    taxResetDay = 27,                         -- Make sure this is set to a valid date 1 day after the tax day
    openMenuRadius = 2,                       -- Radius to open the society management menu (Can not be larger than 49)
    billCommandName = "bill",                 -- Command to open the bill menu
    adminMenuCommandName = "manageSocieties", -- Command to open the admin menu
    receiptsCommandName = "receipts",         -- Command to view your paid receipts

    -- Job types registered in feather-jobs and owned by bcc-society.
    -- Every society picks one job type; every rank maps to one of its grades.
    -- Societies of the same type share the job (e.g. every gun store is
    -- `gunsmith`) and are told apart by the employer, so doors, crafting and
    -- housing can check "gunsmith, grade >= 10" without knowing which store.
    -- Grade keys and ordinals are stable identifiers: add new ones, don't rename.
    Jobs = {
        general_store = {
            label = "General Store",
            ownerGrade = "owner",
            grades = {
                { key = "clerk", label = "Clerk", ordinal = 0 },
                { key = "manager", label = "Manager", ordinal = 10 },
                { key = "owner", label = "Owner", ordinal = 100 }
            }
        },
        gunsmith = {
            label = "Gunsmith",
            ownerGrade = "owner",
            grades = {
                { key = "apprentice", label = "Apprentice", ordinal = 0 },
                { key = "smith", label = "Gunsmith", ordinal = 10 },
                { key = "owner", label = "Owner", ordinal = 100 }
            }
        },
        blacksmith = {
            label = "Blacksmith",
            ownerGrade = "owner",
            grades = {
                { key = "apprentice", label = "Apprentice", ordinal = 0 },
                { key = "smith", label = "Smith", ordinal = 10 },
                { key = "master", label = "Master Smith", ordinal = 20 },
                { key = "owner", label = "Owner", ordinal = 100 }
            }
        },
        saloon = {
            label = "Saloon",
            ownerGrade = "owner",
            grades = {
                { key = "barkeep", label = "Barkeep", ordinal = 0 },
                { key = "manager", label = "Manager", ordinal = 10 },
                { key = "owner", label = "Owner", ordinal = 100 }
            }
        },
        doctor = {
            label = "Doctor",
            ownerGrade = "owner",
            grades = {
                { key = "nurse", label = "Nurse", ordinal = 0 },
                { key = "doctor", label = "Doctor", ordinal = 10 },
                { key = "owner", label = "Head Doctor", ordinal = 100 }
            }
        }
    },

    -- How often the server checks pending hire/promote/fire workflows (ms).
    WorkflowPollMs = 5000,

    blips = {                                 --Blips you can choose when making societies (You can add as many as you want just follow the layout)
        {
            blipName = "Gun Store",
            blipHash = "blip_shop_gunsmith"
        },
        {
            blipName = "Clothing Store",
            blipHash = 'blip_shop_tailor'
        },
        {
            blipName = "General Store",
            blipHash = 'blip_shop_store'
        },
        {
            blipName = "Barber Shop",
            blipHash = 'blip_shop_barber'
        },
        {
            blipName = "Blacksmith",
            blipHash = 'blip_shop_blacksmith'
        },
        {
            blipName = "Doctor Office",
            blipHash = 'blip_shop_doctor'
        },
        {
            blipName = "Stables",
            blipHash = 'blip_shop_horse'
        },
        {
            blipName = "Saloon",
            blipHash = 'blip_saloon'
        }
    }
}
