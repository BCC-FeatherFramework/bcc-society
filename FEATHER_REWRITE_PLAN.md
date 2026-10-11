# BCC Society: Feather rewrite plan

**Status:** ✅ Done 2026-10-11, released as v2.0.0. Every flow passed live with two players (see §9). All D1–D8 recommendations accepted.
**Scope:** phase **J4** of the [Jobs master plan](https://github.com/FeatherFramework/feather-framework-docs/blob/main/feather-jobs/Feather_Jobs_Master_Plan.md). BCC Society becomes the reference consumer of `feather-jobs`.
**Approach:** re-architect, **reusing the existing code**. Keep every file, menu, page flow, translation key and handler structure. Change only:

- **Framework calls:** VORP, `bcc-utils` and feather-menu v1 calls go through small local Feather adapters.
- **Domain state:** jobs, money and storage move to their Feather domains.
- **Validation:** every server handler gets its missing permission check.

The pre-rewrite code is kept untouched in `[bcc]/bcc-society(old)` for reference.

---

## 0. Framework rules (non-negotiable)

The rewrite follows the Feather Framework way only.

**Allowed dependencies**

| Need | Use |
|---|---|
| Database | `feather-mysql` (`@feather-mysql/lib/DB.lua`) |
| Sessions, RPC, locale, events, policy | `feather-core` |
| Character identity | `feather-character` (via Core's `character-profile` provider) |
| Jobs, identity, money, storage, staff permission | `feather-jobs`, `feather-organizations`, `feather-economy`, `feather-inventory`, `feather-authority` |
| Menus | `feather-menu-v2` |
| Prompts, blips, entities | `feather-toolkit` |
| Notifications | `feather-notify` (through Core `SendNotification`) |

**Forbidden.** None of these may appear in the manifest or the code:

- `vorp_core`, `vorp_character`, `vorp_inventory`, or any other `vorp_*`
- `oxmysql` / `MySQL.*`
- `bcc-utils` / `BccUtils`
- `feather-menu` (v1)

**Replacing the legacy calls**

| Legacy call (count today) | Feather replacement |
|---|---|
| `Core.getUser` / `getUsedCharacter`, `charIdentifier` (VORP, 20 refs) | `exports['feather-core']:GetSessionContext(source)` → character UUID |
| `character.money`, `addCurrency`, `removeCurrency` | Economy `Transfer` |
| `character.job`, `setJob`, `setJobGrade`, `group` | feather-jobs exports; Authority `Evaluate` for staff |
| `vorp_inventory` exports | feather-inventory exports |
| `BccUtils.RPC:Register` / `Call` / `CallAsync` / `Notify` (36) | Core `RegisterRPC` / `CallRPCAsync` / `NotifyRPC`, named `bcc-society:<op>` |
| `BccUtils.Prompt:SetupPromptGroup` | Toolkit `CreatePrompt` / `ShowPromptGroup` / `IsPromptCompleted` |
| `BccUtils.Blips:SetBlip` | Toolkit `CreateBlip` / `RemoveBlip` |
| `BccUtils.Discord.*` (22) | Removed (see D7) |
| `BccUtils.Versioner.checkFile` | Removed; feather-versioner handles version checks |
| `RegisterServerEvent` handlers taking client-supplied amounts and IDs | Core RPC routes with payload validation, rate limits, `requireCharacter`, and server-side permission checks |

**Exit check for every phase**, run from `resources/[bcc]/bcc-society`:

```sh
grep -rniE "vorp|oxmysql|MySQL\.|bcc-utils|BccUtils|feather-menu['\"]" .
```

It must print nothing (apart from this plan file).

---

## 1. Why a rewrite

bcc-society 1.4.1 cannot run on this server today. It depends on `vorp_core`, `vorp_character`, `vorp_inventory`, `bcc-utils` and `feather-menu` (v1), and none of these are in `server.cfg`. Its tables reference VORP's integer `characters.charidentifier`.

Beyond the framework mismatch, the server code trusts the client in ways the rewrite must not carry over:

| Area | Legacy behaviour | Risk |
|---|---|---|
| Payroll | Client timer calls `bcc-society:PayEmployee(payAmount, societyId)` with **its own amount** | Any client mints unlimited wages |
| Ledger | `LedgerManagement` checks no rank permission | Any client withdraws any society's ledger |
| Ranks | `RankManagement` checks no permission | Any client edits any society's ranks and permissions |
| Staff actions | `PlayerHired`, `FireEmployee`, `ChangeEmployeeRank` check no permission | Any client hires, fires or promotes anywhere |
| Admin | `AdminManageSociety`, `InsertSocietyToDB` check nothing server-side | Any client deletes or creates societies |
| Billing | Money is taken immediately; the server never checks `rank_can_bill_players` | Forced charges |
| Taxes | Runs only at resource start; branch is inverted (deletes a society that **can't** pay, and logs "paid") | Data loss |
| Duty | Encoded as an `off` prefix on job names and rank names | The exact coupling the Jobs plan removes |
| Shutdown | `onResourceStop` returns on the first offline employee | Remaining employees stay "on duty" |

---

## 2. Current job coupling (inventory)

Everything below is replaced by Jobs contracts.

| Location | Legacy behaviour | Replacement |
|---|---|---|
| `server/services/employees.lua` `PlayerHired` | Inserts employee with `off<rank>`, then `setJob("off<society_job>")` / `setJobGrade` | Membership `pending_assignment` → `CreateAssignment` (`off_duty`) |
| `employees.lua` `FireEmployee` | `setJob("unemployed")`, deletes the row | `EndAssignment`, membership `removed` |
| `employees.lua` `ChangeEmployeeRank` | Updates rank, `setJob(rankName)`, `setJobGrade` | `ChangeAssignmentGrade` using the rank's mapped grade |
| `server/services/jobs.lua` `UpdateJob` / `SwitchJobCommand` | Rewrites `employee_rank`, `setJob` / `setJobGrade`, marks other societies `off*` | `SetActiveAssignment` (rank changes go through managers) |
| `jobs.lua` `ToggleOnDuty` / `ToggleOffDuty` | Strips or adds the `off` prefix on `character.job` and `employee_rank` | `SetDutyState` on the active assignment |
| `jobs.lua` `playerDropped`, `onResourceStop` | Prefixes `off` in the DB and on the character | `SetDutyState(off_duty)` for that character's on-duty assignments |
| `server/services/API.lua` `CheckIfPlayerHasJobAndIsOnDuty`, `GetSocietyByJob` | Reads `character.job` | `CheckAssignment({ jobKey, dutyState = 'on_duty' })` |
| `server/main.lua` `AdminCheck` | VORP group or `Config.AllowedJobs` | Authority capability (see §5) |
| `bcc_society.society_job`, `max_job_grade`; `bcc_society_ranks.society_job_rank` | Job name and numeric grade stored per society | Jobs definition key and grade key mapping (§4) |

Other resources reading `character.job` / `jobGrade` (J5 cutover, not part of this rewrite):

- `bcc-doorlocks/server/server.lua` (lines 54, 393)
- `bcc-craft/server/server.lua` (lines 18–34, 323–334)
- `bcc-housing/server/main.lua` (lines 11, 32–33), `server/services/houses.lua:300`, `server/helpers/functions.lua:24`

No resource other than bcc-society uses `exports['bcc-society']:getSocietyAPI`.

---

## 3. Target ownership

| Concern | Owner after rewrite |
|---|---|
| Society identity (name, status) | **feather-organizations**: one `business` organization per society, key `bcc_society_<id>` |
| Treasury / ledger, wages, bills, taxes | **feather-economy**: the organization's treasury accounts (**blocked**, see §6) |
| Job, grade, assignment, duty, active job | **feather-jobs** |
| Storage | **feather-inventory**: one shared inventory per society |
| Staff permission (create, admin) | **feather-authority** capability, e.g. `staff.society.manage` |
| Character identity | **feather-core** sessions + **feather-character** provider (UUIDs) |
| Location, blip, prompt, menus, ranks, rank permissions, rank → grade mapping, membership, payroll rules, billing UX | **bcc-society** |

bcc-society keeps **no balances, no job strings, and no duty flags**.

---

## 4. Data model (bcc-society v2)

All character references become `CHAR(36)` UUIDs. Migrations are checksummed, following the feather-organizations pattern.

| Table | Key columns |
|---|---|
| `bcc_society_societies` | `society_id`, `organization_id`, `job_key`, `display_name`, `coords`, `blip_hash`, `show_blip`, `inventory_id`, `inv_stage`, `owner_character_id`, `status`, `revision` |
| `bcc_society_ranks` | `rank_id`, `society_id`, `rank_key`, `label`, `grade_key` (**explicit Jobs grade mapping**), `pay_amount`, `pay_interval_minutes`, permission flags, `revision` |
| `bcc_society_memberships` | `membership_id`, `society_id`, `character_id`, `rank_id`, `assignment_id`, `status` (`pending_assignment` · `active` · `pending_removal` · `removed` · `failed`), `revision` |
| `bcc_society_workflows` | Durable outbox: `workflow_id`, `membership_id`, `operation` (`hire` · `promote` · `fire`), `request_id`, `attempts`, `next_attempt_at`, `last_code` |
| `bcc_society_wage_accruals` | `membership_id`, accrued minor units, `last_accrued_at` (server-computed) |
| `bcc_society_bills` | Kept for receipts, with UUID parties and an Economy `transaction_id` |

### Job and grade mapping

Recommended (decision **D2**): Jobs definitions are **shared job types** declared in `Config.Jobs`, not one per society. For example:

```lua
Config.Jobs = {
    blacksmith = {
        label = 'Blacksmith',
        grades = {
            { key = 'apprentice', label = 'Apprentice', ordinal = 0 },
            { key = 'smith', label = 'Smith', ordinal = 10 },
            { key = 'master', label = 'Master Smith', ordinal = 20 }
        }
    }
}
```

- bcc-society registers these at start with stable request IDs and owns them in Jobs.
- Each society picks one `job_key`. Each rank maps to a `grade_key` of that job, and the society owner maps to a configured owner grade.
- Two blacksmith shops share `blacksmith`, and their assignments differ by `employerType = 'society'`, `employerId = <organization_id>`.
- Consumers (doors, crafting, housing) check `jobKey` plus `minGradeOrdinal` and never need to know which shop.

---

## 5. Flows

### Hire (plan sequence, with recovery)

1. The server derives the manager's session and checks the rank permission `manage_employees` for **this** society.
2. In one Society transaction: insert the membership as `pending_assignment` and a `hire` workflow row with `request_id = society:hire:<membership_id>`.
3. A worker calls `CreateAssignment` with `employerType = 'society'`, `employerId = organization_id`, `provenanceType = 'society_membership'`, `provenanceId = membership_id`, `dutyState = 'off_duty'`, and `actorSource` = the manager.
4. On success: store `assignment_id`, set the membership to `active`, delete the workflow row, notify both players.
5. On `transaction_failed` or a timeout: keep it pending and retry with the **same** `request_id` (call `FindOperation` first). On a hard error (`job_inactive`, `assignment_limit`, …): set the membership to `failed` and show the reason to the manager.
6. On restart, the worker resumes every pending workflow. `SocietyReconcile` (console) lists stuck or failed workflows.

Promote and fire use the same workflow table (`ChangeAssignmentGrade` / `EndAssignment`), each with its own stable request ID.

### Duty and switching

- `/onDuty`, `/offDuty` → `SetDutyState` on the player's active Society assignment.
- `/switchjob <society>` and the job menu → `SetActiveAssignment`, then optionally on duty.
- `playerDropped` and Society shutdown → `off_duty` for that character's on-duty Society assignments. Society-owned only; it never touches another resource's assignments.

### Payroll (server-side)

A server loop accrues `pay_amount` every `pay_interval_minutes` **only** while `CheckAssignment` reports `dutyState = 'on_duty'`. "Collect pay" transfers the accrued amount treasury → wallet (`society.payroll`) with an idempotency key per accrual period. Nothing is paid without enough money in the treasury.

---

## 6. Dependencies and blockers

| Domain | Needed | State |
|---|---|---|
| feather-jobs | `bcc-society` in Access `trustedReaders`, `trustedRegistrars`, `trustedAssigners`, `trustedAuditors`; Admin `servicePolicy['feather-jobs']['bcc-society']` | Ready. Config entries only |
| feather-organizations | `trustedCreators`, `trustedMutators`, `trustedReaders`; Admin `servicePolicy['feather-organizations']['bcc-society']` (create, update) | Ready. Same as bcc-banks |
| feather-authority | Register `staff.society.manage` and a staff role, as bcc-banks does for `staff.banks.manage` | Ready. Pattern exists |
| feather-inventory | One shared inventory per society; receipt item grant | Ready. bcc-banks safety-deposit boxes use the same exports |
| **feather-economy** | Society must **debit** its own organization treasury (withdraw, payroll, taxes) and **credit** it (deposit, bills) | **Blocked.** Treasuries can only be debited for bank-reserve products or shop reversals today (`journal.lua` `AccountTypesAllowed`) |

### Economy decision (D5)

Economy needs a small contract addition before money can move. Recommended: generalize `EnsureBankReserve` into an **operated treasury** binding, where an organization treasury is bound permanently to one operator resource, plus a `society.*` reason family that Economy validates:

| Reason | From → To |
|---|---|
| `society.deposit` | Acting character's wallet → bound treasury |
| `society.withdraw` | Bound treasury → acting character's wallet (Society checks the rank permission first) |
| `society.payroll` | Bound treasury → employee wallet |
| `society.bill` | Customer wallet → bound treasury (customer accepts first, see D6) |
| `society.tax` | Bound treasury → system sink |

Until this lands, phases S1–S4 below can ship **without money**.

---

## 7. Decisions needed

| # | Decision | Accepted |
|---|---|---|
| **D1** | Legacy data: migrate VORP-era `bcc_society*` rows or start fresh? | **Start fresh.** Checked 2026-10-02: none of the legacy tables exist in the database |
| **D2** | Jobs definitions: shared job types in config, or one job per society? | **Shared job types** (§4). Consumers check `blacksmith`, not a specific shop |
| **D3** | Does the owner hold a Jobs assignment? | **Yes**, at a configured owner grade, so owners pass job checks and can go on duty |
| **D4** | Can employees work at several societies? (`employeeWorksAtMultiple`) | **Yes**. Jobs already allows up to 8 open assignments, and the active selection replaces `off` prefixes |
| **D5** | Economy operated-treasury contract (§6) | Approve the addition. **The Economy owner should implement it**, not Society |
| **D6** | Billing: charge immediately (legacy) or require the customer to accept? | **Customer accepts** a bill prompt, then `society.bill` transfer |
| **D7** | Discord webhooks | Drop them for now. Committed facts come from Jobs, Organizations and Economy events and Audit; add a small optional webhook listener later |
| **D8** | Development layout | Rewrite in place as `bcc-society`, keeping the current code as `bcc-society(old)` for reference (same pattern as `bcc-zonenotify(old)`) |

---

## 8. Delivery phases

| Phase | Scope | Exit check |
|---|---|---|
| **S0** | Decisions D1–D8 recorded in this file | Team sign-off |
| **S1** Foundation | Manifest on Feather only (§0), config validation, locale wrapper, v2 migrations, readiness and health | Clean start; the §0 grep prints nothing |
| **S2** Identity and admin | Society ↔ Organization, staff create, edit and dissolve via Authority, blips and prompts | Create a society, restart, still there |
| **S3** Ranks and membership | Rank CRUD with explicit grade mapping, membership states, workflow worker, `SocietyReconcile` | Hire, promote and fire survive a feather-jobs restart mid-workflow |
| **S4** Duty and active job | On/off duty, switch job, menu, disconnect and shutdown handling | `CheckAssignment` reflects duty; no `off` strings anywhere |
| **S5** Money | Deposit, withdraw, payroll, bills, taxes on the operated treasury | Needs D5. Ledger reconciles with Economy |
| **S6** Storage | Society inventory on feather-inventory, upgrade stages | Items persist across restarts |
| **S7** Tests and docs | `SocietyLiveTest <serverId>`, README, release checks | All green on the dev server |

Exit for J4 overall (Jobs plan gates): multiple societies don't overwrite each other's assignments; offline hire, fire and promote work; a Society restart recovers pending workflows; `grep -r "setJob\|\"off\"" bcc-society` returns nothing.

---

## 9. Progress (2026-10-02)

| Phase | State | Notes |
|---|---|---|
| **S0** | ✅ Done | D1–D8 accepted; D1 confirmed (no legacy tables) |
| **S1** Foundation | ✅ Code complete | Feather adapters (`server/feather/init.lua`, `client/feather/init.lua`, `client/feather/menu_v2.lua` from bcc-banks), Core-backed `locale.lua`, manifest on Feather only, UUID schema |
| **S2** Identity and admin | ✅ Code complete | `server/feather/organizations.lua`, `server/feather/authority.lua`, staff checks, job-type picker, dissolve, Toolkit prompts and blips |
| **S3** Ranks and membership | ✅ Code complete | `server/feather/jobs.lua` workflows, rank → grade picker, `SocietyReconcile` |
| **S4** Duty and active job | ✅ Code complete | `server/services/jobs.lua`; off duty on `character.leaving.v1` and shutdown |
| **S5** Money | ✅ Code complete | `server/feather/economy.lua`, `ledger.lua`, `payroll.lua` (server accrual), `billing.lua` (customer accepts), `taxes.lua` (daily loop, monthly idempotency) |
| **S6** Storage | ✅ Code complete | `inventory.lua`: one feather-inventory container per society; paid upgrades |
| **S7** Tests and docs | ✅ Code complete | `SocietyLiveTest`, README |
| **S8** Live acceptance | ✅ Done 2026-10-11 | Two players: every flow below; v2.0.0 tagged |

**Live checkpoint (2026-10-02):** `SocietyLiveTest 1` passed **9/9** on the dev server: organization link, owner assignment at the owner grade, duty on/off, treasury read, dissolve (owner job ended, organization dissolved).

Two fixes were needed first:
- The shared resources had to be restarted to load the new trust entries.
- The manifest loaded some files twice (an explicit entry plus a glob, inherited from the original). It now lists each file once.

**Live checkpoint (2026-10-11):** `SocietyLiveTest` passed **12/12** with two players (hire,
promote, fire). With the `SocietyDev*` console tools, offline hire, promote (nurse(0) to
doctor(10), same assignment, revision 3 to 4) and fire passed; a restart right after a queued
workflow left `SocietyReconcile` at 0 open; duty on/off and disconnect (`SocietyDevLeave`)
behaved and never changed the job or grade; two societies kept separate assignments, the
active job switched, and firing from one ended only that job. In game: create, rename, ranks,
hire, fire, re-hire, bill sent and dissolve worked. Storage opens after the 500-slot cap fix
(a 123456 limit was rejected by feather-inventory's SMALLINT); items move in and out,
equipped weapons are refused until unequipped. Ledger deposit and withdraw worked in game
(wallet funded with feather-admin `/givemoney`; DBG showed 2948 + 1232 = 4180, then
4180 - 1542 = 2638, each one Economy transfer).
Taxes on the creation day (`Config.taxOnCreationDay`, `SocietyDevTaxes`): the day before was
skipped ("due on day 11"); on the day sadas paid 1234 once (`taxes_paid` = 202611) and a repeat
run did not charge it again; Doctor failed with `insufficient_funds`, stayed unpaid and retries
(a failed transfer rolls back its idempotency reservation in Economy).
Bills with a second player: bill 4 (1500) and bill 5 (100) were accepted and paid into the
treasury (2638 -> 4138 -> 4238, one `society.bill` transfer each); bill 6 was declined and moved
no money. The bill window needed the menu-recovery fix (feather-menu-v2 had lost the menu).
Payroll: with rank qwer at 10 every 1 minute, on-duty minutes accrued 10 per minute; the
employee collected 10 from the treasury (`society.payroll`, owed went back to 0) and accrual
continued.

Also verified live on 2026-10-11: a second collection inside the cooldown is refused and wages
stop off duty; a bill left unanswered for 2 minutes expires without moving money; storage keeps
its items across a restart and a paid upgrade adds its slots; dissolving removes the prompt and
blip on both players' screens and fires the employees.

**Live acceptance complete.** No flow is left unverified.

### Shared resources changed for this rewrite

| Resource | Change |
|---|---|
| feather-jobs `config.lua` | `bcc-society` in `trustedReaders`, `trustedRegistrars`, `trustedAssigners`, `trustedAuditors` |
| feather-organizations `config.lua` | `bcc-society` in `trustedCreators`, `trustedMutators`, `trustedReaders`; `feather-jobs` in `trustedReaders` |
| feather-authority `config.lua` | `bcc-society` in the five lists `bcc-banks` uses |
| feather-admin `configs/service_policy.lua` | Jobs and Organizations actions for `bcc-society` |
| feather-economy | **LOCAL ADDITION**: `EnsureOperatedTreasury` (api.lua), `society.*` reasons in `SocietyTransferAllowed` (journal.lua), `trustedTreasuryOperators` plus `bcc-society` in reader/provisioner/transactor lists (config.lua). **The Economy owner should review these.** |

### Known gaps

- **Receipt item:** paid receipts are a `/receipts` list. The old `bcc_society_receipt` item needs an item definition in feather-inventory before it can return.
- **Storage upgrade:** charged to the player's wallet, as in the original; it could move to the treasury later.
- **J5:** bcc-doorlocks and bcc-craft use `CheckAssignment` since their 2.0.0 ports; bcc-housing still reads `character.job` (not ported).

### First live run

1. Restart, in order: `feather-economy`, `feather-organizations`, `feather-authority`, `feather-jobs`, `feather-admin`.
2. `ensure bcc-society` and look for `jobs: ready (5 job types)` and `organizations: ... ready`.
3. Run `SocietyLiveTest <yourServerId> [secondPlayerId]` and expect every line to PASS.
4. Then try it in game: `SocietyAdminGrant <id>`, `/createSociety`, ranks, hire, `/onDuty`, ledger, `/bill`.
