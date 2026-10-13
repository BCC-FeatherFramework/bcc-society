# BCC-Society

> Societies (businesses) for RedM on the **Feather Framework**: owners, employees, ranks, duty, ledger, payroll, billing, taxes and storage.

Version **2.0.0** is the Feather rewrite. It keeps the original menus, page flows and translation keys. All ownership and state now live in the Feather domain resources:

| Concern | Owner |
|---|---|
| Society identity | `feather-organizations` (one `business` organization per society) |
| Ledger, wages, bills, taxes | `feather-economy` (the organization's treasury) |
| Job, grade, duty, active job | `feather-jobs` |
| Storage | `feather-inventory` (one shared container per society) |
| Staff permission | `feather-authority` (`staff.society.manage`) |
| Characters | `feather-core` sessions + `feather-character` |

bcc-society keeps societies, ranks, rank permissions, memberships and the rank → grade mapping. It has no VORP, `bcc-utils` or oxmysql code.

The rewrite plan, decisions and progress are in [FEATHER_REWRITE_PLAN.md](FEATHER_REWRITE_PLAN.md). The pre-rewrite code is kept in `[bcc]/bcc-society(old)`.

---

## Features

- **Societies:** staff create them where they stand, with a name, owner, job type, blip, tax and storage plan.
- **Job types:** shared feather-jobs jobs from `Config.Jobs` (e.g. every gun store is `gunsmith`). Doors, crafting and housing can check "gunsmith, grade ≥ 10" without knowing which store.
- **Ranks:** each rank has pay, permissions, and an explicit mapping to one grade of the society's job type.
- **Employees:** hire, promote and fire through durable workflows that survive restarts. Employees can work at several societies.
- **Duty:** `/onDuty`, `/offDuty`, `/switchjob`, `/jobManagement`. Duty is per assignment in feather-jobs. Logout, disconnect and shutdown put people off duty.
- **Ledger:** deposit and withdraw between your wallet and the society treasury, gated by rank permission.
- **Payroll:** wages accrue on the server only while on duty; employees collect them from the treasury.
- **Billing:** `/bill` sends a bill; the customer accepts or declines before any money moves. `/receipts` lists paid receipts.
- **Taxes:** paid from the treasury once per month. With `Config.taxOnCreationDay = true` (default) each
  society pays on the day of the month it was created (the last day of shorter months), starting the month
  after creation; if the server was down that day it pays at the next hourly check. With `false`, every
  society pays on `Config.taxDay`. A society that can't pay is reported to its owner, not deleted.
- **Storage:** a shared feather-inventory container with paid upgrade stages, up to
  `Config.MaxStorageSlots` (500). Equipped weapons cannot be stored: unequip them first
  (feather-inventory shows "Unequip this item before moving or removing it.").
- **Blips and prompts:** through feather-toolkit.
- **Translations:** English (`en_us`), Polish (`pl`) and Romanian (`ro`), registered through feather-core.

---

## Requirements

Start these before `bcc-society`:

`feather-mysql`, `feather-core`, `feather-character`, `feather-notify`, `feather-toolkit`, `feather-menu-v2`, `feather-jobs`, `feather-economy`, `feather-inventory`, `feather-organizations`, `feather-authority`

### Trust entries

bcc-society must be trusted by:

| Resource | Entries |
|---|---|
| feather-jobs `config.lua` | `trustedReaders`, `trustedRegistrars`, `trustedAssigners`, `trustedAuditors` |
| feather-organizations `config.lua` | `trustedCreators`, `trustedMutators`, `trustedReaders`; plus `feather-jobs` in `trustedReaders` |
| feather-authority `config.lua` | `trustedReaders`, `trustedCapabilityRegistrars`, `trustedRoleCreators`, `trustedGrantors`, `trustedAssigners` |
| feather-economy `config.lua` | `trustedTreasuryOperators`, `trustedReaders`, `trustedProvisioners`, `trustedTransactors` |
| feather-admin `configs/service_policy.lua` | `['feather-jobs']['bcc-society']` and `['feather-organizations']['bcc-society']` |

Add `['bcc-society'] = true` to each listed group and keep the entries already there. Examples:

**feather-jobs/config.lua** (already present in the shipped config):

```lua
Access = {
    trustedReaders = { ['feather-jobs'] = true, ['feather-admin'] = true, ['bcc-society'] = true },
    trustedRegistrars = { ['feather-jobs'] = true, ['feather-admin'] = true, ['bcc-society'] = true },
    privilegedRegistrars = { ['feather-admin'] = true },
    trustedAssigners = { ['feather-jobs'] = true, ['feather-admin'] = true, ['bcc-society'] = true },
    privilegedAssigners = { ['feather-admin'] = true },
    trustedAuditors = { ['feather-jobs'] = true, ['feather-admin'] = true, ['bcc-society'] = true },
    privilegedAuditors = { ['feather-admin'] = true }
}
```

**feather-organizations/config.lua** (`feather-jobs` also reads, to validate employer organizations):

```lua
Access = {
    trustedCreators = { ['feather-organizations'] = true, ['feather-admin'] = true, ['feather-shops'] = true,
        ['bcc-society'] = true },
    trustedMutators = { ['feather-organizations'] = true, ['feather-admin'] = true, ['feather-shops'] = true,
        ['bcc-society'] = true },
    -- privilegedMutators, trustedAuditors, privilegedAuditors unchanged
    trustedReaders = {
        ['feather-organizations'] = true,
        ['feather-admin'] = true,
        ['feather-economy'] = true,
        ['feather-shops'] = true,
        ['feather-jobs'] = true,
        ['bcc-society'] = true
    }
}
```

**feather-authority/config.lua** (all five groups; the society staff role and its capability are registered by bcc-society):

```lua
Access = {
    trustedReaders = { ['feather-authority'] = true, ['feather-admin'] = true, ['bcc-society'] = true },
    trustedCapabilityRegistrars = { ['feather-authority'] = true, ['feather-admin'] = true, ['bcc-society'] = true },
    trustedRoleCreators = { ['feather-authority'] = true, ['feather-admin'] = true, ['bcc-society'] = true },
    trustedGrantors = { ['feather-authority'] = true, ['feather-admin'] = true, ['bcc-society'] = true },
    trustedAssigners = { ['feather-authority'] = true, ['feather-admin'] = true, ['bcc-society'] = true }
}
```

**feather-economy/config.lua** (keep the existing entries in each group). `trustedTreasuryOperators`
exists only in a feather-economy build with the operated accounts extension
(`EnsureOperatedTreasury`, `RegisterOperatedReasons`); without it the society ledger, payroll,
billing and taxes are unavailable. bcc-society registers its own reason codes (`society.deposit`,
`society.bill`, `society.withdraw`, `society.payroll`, `society.tax`) on start; nothing else to configure.

```lua
Access = {
    -- May bind organization treasuries and register reason codes that move them.
    -- They must also be in trustedTransactors.
    trustedTreasuryOperators = { ['bcc-society'] = true },
    trustedReaders = { ['feather-economy'] = true, --[[ ... ]] ['bcc-society'] = true },
    trustedProvisioners = { ['feather-economy'] = true, --[[ ... ]] ['bcc-society'] = true },
    trustedTransactors = { ['feather-economy'] = true, --[[ ... ]] ['bcc-society'] = true }
}
```

**feather-admin/configs/service_policy.lua** (the outer key is the domain that asks for the policy
decision, the inner key is the calling resource; grant only the actions bcc-society uses):

```lua
Config.servicePolicy = {
    ['feather-organizations'] = {
        -- existing feather-shops / feather-organizations / feather-admin entries
        ['bcc-society'] = {
            ['organizations.organization.create']=true,
            ['organizations.organization.update']=true,
            ['organizations.organization.dissolve']=true
        }
    },
    ['feather-jobs'] = {
        ['bcc-society'] = {
            ['jobs.definition.manage']=true,
            ['jobs.assignment.manage']=true
        }
    }
}
```

Then restart the changed resources in order, and bcc-society last:

```text
restart feather-economy
restart feather-organizations
restart feather-authority
restart feather-jobs
restart feather-admin
ensure bcc-society
```

Both problems return `authorization_denied`. A missing trust entry says the calling resource is not
trusted; a missing service policy grant says the policy denied it, with `policyCode=service_forbidden`
in the details where the resource reports it.

---

## Admin

| Command | Who | Purpose |
|---|---|---|
| `/createSociety` | Staff | Create a society at your position |
| `/manageSocieties` | Staff | Rename, retax, re-blip or dissolve societies |
| `SocietyAdminGrant <id>` / `SocietyAdminRevoke <id>` | Console | Give or remove the society staff role |
| `SocietyReconcile` | Console | List hire/promote/fire workflows that are still pending or failed |
| `SocietyLiveTest <owner id> [employee id]` | Console, dev mode | **Mutating** end-to-end test on a throwaway society |

Staff means Feather Admin owners or administrators, holders of `staff.society.manage`, or characters with a job listed in `Config.AllowedJobs`.

The job type is fixed after creation. Dissolving a society ends every member's job, dissolves its organization and keeps the row as history.

---

## Development tools (dev mode)

With `Config.devMode = true`, these server-console commands stand in for a second
player. They act on any character, online or offline, given as a server ID or a
character UUID, and use the same membership and feather-jobs paths as the menus.

| Command | Purpose |
|---|---|
| `SocietyDevChars` | List online players and every society member with their character UUIDs |
| `SocietyDevStatus <character>` | Show the character's feather-jobs assignments (job, grade, duty, active) |
| `SocietyDevHire <society id> <character> [rank]` | Hire (entry rank when omitted) |
| `SocietyDevRank <society id> <character> <rank>` | Change rank and Jobs grade |
| `SocietyDevFire <society id> <character>` | Fire |
| `SocietyDevDuty <character> <on\|off> [society id]` | Put on or off duty |
| `SocietyDevSwitch <character> <society id>` | Make that society's job the active one |
| `SocietyDevLeave <character>` | Do what a disconnect does: take every society job off duty |
| `SocietyDevTaxes [YYYY-MM-DD]` | Run the tax check now, as if it were that date (moves real money; each society still pays at most once per month) |

---

## Configuration

See [config.lua](config.lua). The parts specific to Feather:

- `Config.Jobs`: the job types and their grades (keys and ordinals are stable identifiers; add new ones rather than renaming). `ownerGrade` is the grade the society owner holds.
- `Config.Admin`: the Authority capability, role and accepted Feather Admin staff roles.
- `Config.NotifyStyle`: the feather-notify style for player messages.
- `Config.WorkflowPollMs`: how often pending Jobs workflows are retried.

---

## Society API

`exports['bcc-society']:getSocietyAPI()` returns the same `SocietyAPI` as before, with these changes:

- Character IDs are Feather UUIDs.
- `society:GetEmployeeRank(charId)` returns the plain rank name (there are no `off` prefixes).
- `society:GetLedgerAmount()` reads the Economy treasury balance, in dollars.
- `AddMoneyToLedger` and `RemoveMoneyFromLedger` are removed: money only moves through Economy.
- `SocietyAPI.MiscAPI:CheckIfPlayerHasJobAndIsOnDuty(jobKey, source)` asks feather-jobs.

For job checks in other resources, prefer feather-jobs directly:

```lua
local result = exports['feather-jobs']:CheckAssignment({
    characterId = characterId,
    jobKey = 'gunsmith',
    minGradeOrdinal = 10,
    dutyState = 'on_duty'
})
if result.ok and result.value.matched then
    -- allowed by your own rule
end
```
