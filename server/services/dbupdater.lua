DBUpdated = false

CreateThread(function()
    DB.awaitReady()

    -- Societies. Identity lives in feather-organizations (organization_id),
    -- money in feather-economy (the organization's treasury), and the job in
    -- feather-jobs (society_job is a Config.Jobs key). Character IDs are UUIDs.
    DB.exec([[
        CREATE TABLE IF NOT EXISTS `bcc_society` (
            `business_id` int AUTO_INCREMENT,
            `business_name` varchar(100) NOT NULL,
            `organization_id` CHAR(36) NULL,
            `status` varchar(16) NOT NULL DEFAULT 'active',
            `blip_hash` varchar(255) NOT NULL DEFAULT 'none',
            `show_blip` varchar(6) NOT NULL DEFAULT "true",
            `tax_amount` int(30) NOT NULL DEFAULT 0,
            `taxes_paid` char(6) NOT NULL DEFAULT "false",
            `inv_limit` int(30) NOT NULL DEFAULT 0,
            `coords` LONGTEXT NOT NULL,
            `inventory_upgrade_stages` LONGTEXT NOT NULL,
            `inventory_current_stage` int(40) NOT NULL DEFAULT 0,
            `inventory_id` varchar(64) NULL,
            `owner_id` CHAR(36) NOT NULL,
            `owner_assignment_id` CHAR(36) NULL,
            `society_job` varchar(48) NOT NULL,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`business_id`),
            UNIQUE KEY `uq_bcc_society_organization` (`organization_id`),
            KEY `idx_bcc_society_owner` (`owner_id`),
            CONSTRAINT `chk_bcc_society_status` CHECK (`status` IN ('active','dissolved'))
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    -- Memberships. employee_rank is the rank name only (never an "off" prefix);
    -- duty lives on the feather-jobs assignment. employee_payment is wages owed
    -- (whole dollars), paid out of the society treasury on collection.
    DB.exec([[
        CREATE TABLE IF NOT EXISTS `bcc_society_employees` (
            `business_id` int NOT NULL,
            `employee_id` CHAR(36) NOT NULL,
            `employee_name` varchar(255) NOT NULL,
            `employee_rank` varchar(100) NOT NULL,
            `employee_payment` int(11) NOT NULL DEFAULT 0,
            `assignment_id` CHAR(36) NULL,
            `status` varchar(24) NOT NULL DEFAULT 'pending_assignment',
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`business_id`, `employee_id`),
            KEY `idx_bcc_society_employee` (`employee_id`),
            FOREIGN KEY (`business_id`) REFERENCES `bcc_society`(`business_id`) ON DELETE CASCADE,
            CONSTRAINT `chk_bcc_society_employee_status` CHECK (`status` IN
                ('pending_assignment','active','pending_removal','failed'))
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    -- Ranks. job_grade is the explicit mapping to a feather-jobs grade key of the
    -- society's job type; a rank never *is* a job grade.
    DB.exec([[
        CREATE TABLE IF NOT EXISTS `bcc_society_ranks` (
            `business_id` int NOT NULL,
            `rank_name` varchar(100) NOT NULL,
            `rank_label` varchar(255) NOT NULL DEFAULT 'none',
            `rank_pay` int(30) NOT NULL,
            `rank_pay_increment` int(30) NOT NULL,
            `job_grade` varchar(48) NOT NULL,
            `rank_can_toggle_blip` char(6) NOT NULL DEFAULT "false",
            `rank_can_withdraw` char(6) NOT NULL DEFAULT "false",
            `rank_can_deposit` char(6) NOT NULL DEFAULT "false",
            `rank_can_edit_ranks` char(6) NOT NULL DEFAULT "false",
            `rank_can_manage_employees` char(6) NOT NULL DEFAULT "false",
            `rank_can_open_inventory` char(6) NOT NULL DEFAULT "false",
            `rank_can_manage_store` char(6) NOT NULL DEFAULT "false",
            `rank_can_bill_players` char(6) NOT NULL DEFAULT "false",
            `rank_can_switch_job` char(6) NOT NULL DEFAULT "true",
            PRIMARY KEY (`business_id`, `rank_name`),
            FOREIGN KEY (`business_id`) REFERENCES `bcc_society`(`business_id`) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    -- Durable Jobs workflows (hire, promote, fire, owner). Each row keeps one
    -- stable request ID, so retries after a timeout or restart never duplicate.
    DB.exec([[
        CREATE TABLE IF NOT EXISTS `bcc_society_workflows` (
            `workflow_id` CHAR(36) NOT NULL,
            `business_id` int NOT NULL,
            `character_id` CHAR(36) NOT NULL,
            `operation` varchar(16) NOT NULL,
            `request_id` varchar(128) NOT NULL,
            `grade_key` varchar(48) NULL,
            `actor_source` int NULL,
            `status` varchar(16) NOT NULL DEFAULT 'pending',
            `attempts` int NOT NULL DEFAULT 0,
            `last_code` varchar(64) NULL,
            `next_attempt_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`workflow_id`),
            UNIQUE KEY `uq_bcc_society_workflow_request` (`request_id`),
            KEY `idx_bcc_society_workflow_pending` (`status`, `next_attempt_at`),
            CONSTRAINT `chk_bcc_society_workflow_operation` CHECK (`operation` IN ('hire','promote','fire','owner')),
            CONSTRAINT `chk_bcc_society_workflow_status` CHECK (`status` IN ('pending','done','failed'))
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    DB.exec([[
        CREATE TABLE IF NOT EXISTS `bcc_society_bills` (
            `id` INT AUTO_INCREMENT PRIMARY KEY,
            `billed_identifier` CHAR(36) NOT NULL,
            `biller_identifier` CHAR(36) NOT NULL,
            `billed_name` VARCHAR(150),
            `biller_name` VARCHAR(150),
            `amount` INT NOT NULL,
            `society_id` INT NULL,
            `description` TEXT,
            `timestamp` INT NOT NULL,
            `status` VARCHAR(10) DEFAULT 'PENDING',
            `transaction_id` CHAR(36) NULL
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    DBUpdated = true

    print("Database table \x1b[35m\x1b[1m*bcc_society*\x1b[0m created or updated \x1b[32msuccessfully\x1b[0m.")
end)
