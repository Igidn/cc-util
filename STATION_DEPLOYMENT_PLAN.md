# Miner Station Deployment — Automation Plan

**Repository:** `cc-util`  
**Target:** Fully automated, console-manageable miner station deployment  
**Status:** Planning (pre-implementation)

---

## 1. Executive Summary

Today every turtle is installed manually: the installer registers the turtle, downloads the Lua runtime, and reboots. There is no role selection, no station construction, no hauling, and no coordination between turtles sharing a shaft.

The goal is to make station deployment fully automated and manageable from the console:

1. **Installer** registers the turtle, then the console prompts the operator to assign a role: **station builder**, **miner**, or **hauler**.
2. **Station builder** travels to its anchor, verifies surface chests (fuel front, depot back), mines a shaft down to Y10, digs a 10×10 room, places 32 numbered underground storage chests plus 1 refueling chest (33 total) in an accessible pattern, logs every chest position+ID to the console, then transitions into a **hauler**.
3. **Hauler** fulfills two jobs: (a) bring player-requested ores/blocks up from underground storage to the surface depot chest, (b) bring fuel (lava) down to the miners' refueling chest.
4. **Miner** is placed at the shaft entrance on the surface, runs the installer, selects "miner", picks a station, and descends the shaft.
5. **Queuing system:** one shaft per station. A server-managed mutex prevents two turtles from occupying the shaft or station at once.
6. **Simulation first:** everything is validated in a mock-Lua environment before any real turtle is deployed. Miner population grows one station at a time.

This plan assumes **GPS is available on all turtles** (per requirements) and uses it for absolute positioning, with the existing dead-reckoning dock re-zero as a fallback.

---

## 2. Current Architecture (what exists)

| Layer | Location | Responsibility |
|---|---|---|
| Turtle runtime | `mine/` | CC: Tweaked Lua. `install.lua` → `main.lua` → `link.lua` (WebSocket) + `supervisor.lua` (mission loop) + `miner.lua` (trip executor). |
| Pose / movement | `mine/lib/pose.lua`, `nav.lua`, `tape.lua`, `safety.lua` | Dead reckoning, trip tape stack, fuel-reserve invariant, GPS sync. |
| Docking | `mine/lib/dock.lua` | Physical fixture re-zero (down/back/left walls), GPS fallback. |
| Console server | `console/src/` | Node/TS HTTP + WebSocket hub. `registry.ts` (registration, stations, roles), `mission.ts` (branchMine/timber specs), `store.ts` (JSON file), `hub.ts` (commands: start/abort/return/ping). |
| Console web | `console/web/` | React/Vite operator UI. Mining tab, Fleet tab, etc. Roles exist (`miner`, `lumberjack`, `hauler`, `unassigned`) but **hauler is not wired**. |
| Publishing | `console/src/publish.ts` | Writes runtime manifest, uploads to fixed GitHub release tag `tunnel-latest`. |

Key files already read: `mine/install.lua`, `mine/main.lua`, `mine/lib/{identity,state,nav,gps,miner,dock,link,supervisor,hal,plan,pose,resolve,safety,tape,util}.lua`, `mine/test/test.lua`, `console/src/{index,hub,registry,mission,store,http,plan,map,config,realtime,tunnel,publish}.ts`, `console/shared/api.ts`, `console/web/src/tabs/{mining,fleet}.tsx`, `console/web/src/components/mining/mission-controls.tsx`, `docs/mining-network-design.md`.

---

## 3. Target Architecture (what we're building)

### 3.1 Roles

| Role | Lua module | Purpose |
|---|---|---|
| `station_builder` | `mine/lib/station_builder.lua` | Builds the station: shaft, 10×10 room, 33 storage chests, refueling chest, surface chests. Then becomes hauler. |
| `miner` | `mine/lib/miner.lua` (existing, extended) | Descends shaft, branch-mines its sector, deposits ores into underground storage chests. |
| `hauler` | `mine/lib/hauler.lua` (new) | Fulfills player item requests (up) and miner fuel requests (down). |
| `unassigned` | — | Freshly registered, awaiting console role assignment. |

### 3.2 Station layout (per station)

```
Surface (world Y = BASE_Y, e.g. 10)
  [fuel chest]  [turtle spawn point]  [depot chest]
        front                          back
              |
              |  shaft (1×1, down to Y10)
              v
Underground room at Y10 (10×10)
  +------------------------------------+
  | C C . C C . C C . C | aisle        |  <- storage chests (32 total)
  | C C . C C . C C . C |              |
  | . . . . . . . . . . |              |
  | C C . C C . C C . C |              |
  | C C . C C . C C . C |              |
  | . . . R . . . . . . | R = refueling chest (near shaft bottom)
  | C C . C C . C C . C |              |
  | C C . C C . C C . C |              |
  | . . . . . . . . . . |              |
  | . . . S S S S S . . | S = shaft bottom access
  +------------------------------------+
              |
              |  down to mining layers (Y10 → bottomWorldY)
```

- **32 underground storage chests**: each has a unique chest ID (station-scoped, e.g. `s0-c001`…`s0-c032`), position logged to console. Made for miners to deposit ores/blocks directly.
- **1 refueling chest**: ID `s0-c-refuel`, adjacent to downward shaft at Y10, holds fuel (lava buckets) for miners. Hauler replenishes it.
- **2 surface chests**: front = fuel for station builder/hauler; back = depot chest for player-requested items (hauler brings items up here).
- **1 fuel chest (lava)**: separate from depot, source of lava buckets hauler delivers to miners. One lava bucket = 1,000 fuel to a turtle; empty buckets can be discarded.
- **Capacity thresholds** (of the 32 storage chests):
  - **3/4 full (24 chests)** → console notification: player should set up a surface depot.
  - **3.5/4 full (28 chests)** → hauler automatically starts moving items up to the surface storage depot.

### 3.3 Lifecycle

```
installer runs on turtle
  → register with server (role = "unassigned")
  → server marks turtle as "pending role"
  → console shows prompt: "Turtle <id> needs role: station_builder / miner / hauler"
  → operator selects role on console
  → server stores turtle.role
  → installer downloads runtime, reboots
turtle reboots, main.lua starts
  → connects via WebSocket, welcome includes role
  → supervisor loads role-specific module
  → station_builder: builds station → transitions to hauler
  → miner: requests shaft access → descends → mines
  → hauler: waits for requests → fulfills up/down jobs
```

---

## 4. Data Model Changes

Additions to `console/shared/api.ts` and `console/src/store.ts`:

### 4.1 New types

```ts
export type TurtleRole = "miner" | "lumberjack" | "hauler" | "unassigned" | "station_builder";

### Chest data structure (answers: yes, position is stored)

Every chest stores its absolute world position via the `pose` field:

```ts
export type Chest = {
  id: string;              // e.g. "s0-c001", "s0-c032", "s0-c-refuel"
  stationId: string;       // e.g. "s0"
  kind: "storage" | "refuel" | "depot" | "fuel";
  pose: Pose;              // { x: number, y: number, z: number, f: Facing } — YES, x/y/z stored
  label?: string;
  filledAt?: number;
  requestedBy?: string;
  fillPercent?: number;    // 0-100 estimated fill level
};
```

`Pose` is defined in `shared/api.ts` as `Vec3 & { f: Facing }`, so `pose.x`, `pose.y`, `pose.z` are the absolute world coordinates (GPS position) where the chest was placed. The turtle logs this to the console when it places each chest, and the console uses it to render the chest map on the station detail view.

Chest IDs are station-scoped: `s<stationId>-cNNN` (e.g. `s0-c001`, `s0-c032`) for the 32 storage chests, and `s<stationId>-c-refuel` for the refueling chest. This prevents ID collisions across stations and makes it trivial to look up all chests belonging to a given station.

export type ItemRequest = {
  id: string;
  stationId: string;
  requestedBy: string;     // operator / player name
  itemName: string;        // e.g. "minecraft:iron_ore"
  count: number;
  status: "pending" | "assigned" | "delivered" | "cancelled";
  haulerId?: string;
  createdAt: number;
  updatedAt: number;
};

export type ShaftLock = {
  stationId: string;
  holderTurtleId: string | null;   // currently in the shaft
  queue: string[];                 // waiting turtle ids (FIFO)
  acquiredAt: number | null;
  expiresAt: number | null;        // auto-release timeout
};

export type Station = {
  ...existing fields...
  name: string;                  // auto-generated, e.g. "Station Alpha", "Station Bravo"
  shaftPose: Pose | null;        // world position of shaft top
  roomPose: Pose | null;         // world position of 10×10 room center (Y10)
  built: boolean;                // station builder finished
  chests: Chest[];               // registry of all chests
  storageChestCount: number;     // 32
  storageChestsFilled: number;   // how many storage chests have ore/blocks
  depotNotifiedAt: number | null; // when 3/4 threshold was first reported
  haulerEvacuatingAt: number | null; // when 3.5/4 threshold triggered hauler move-up
};
```

### 4.2 Store additions

`StoreData` gains:
- `chests: Record<string, Chest>` (keyed by chest id)
- `requests: Record<string, ItemRequest>`
- `shaftLocks: Record<string, ShaftLock>` (keyed by station id)
- `Station.name`, `Station.shaftPose`, `Station.roomPose`, `Station.built`

---

## 5. Console Changes (server + UI)

### 5.1 New HTTP endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/api/turtles/<id>/role-request` | none (turtle) | Turtle tells console it needs a role. Creates pending role request. |
| GET | `/api/turtles/pending` | admin | List turtles awaiting role assignment. |
| POST | `/api/turtles/<id>/assign-role` | admin | Body `{ role }`. Sets turtle.role, clears pending request. |
| GET | `/api/chests` | admin | List all chests with station, kind, pose, id. |
| GET | `/api/chests/<stationId>` | admin | Chests for one station. |
| POST | `/api/requests` | admin | Create an item request (player wants ores/blocks up). |
| GET | `/api/requests` | admin | List pending/active requests. |
| POST | `/api/requests/<id>/cancel` | admin | Cancel a request. |
| POST | `/api/shaft/<stationId>/acquire` | none (turtle) | Request shaft access. Returns granted/queued/rejected. |
| POST | `/api/shaft/<stationId>/release` | none (turtle) | Release shaft access, notify next in queue. |
| GET | `/api/shaft/<stationId>/status` | none | Current lock holder and queue. |
| POST | `/api/stations/<stationId>/gps-alert` | none (turtle) | Turtle reports no GPS access; console notifies player. |
| POST | `/api/stations/<stationId>/reload` | admin | Reload/resume a turtle after GPS is restored. |

### 5.2 Console capacity notifications

The console monitors `storageChestsFilled` per station:

- **At 24/32 (3/4)** filled: emit an attention event + UI notification telling the operator to set up a surface depot. Sets `depotNotifiedAt`.
- **At 28/32 (3.5/4)** filled: automatically instruct the station's hauler to begin moving items up from underground storage chests to the surface depot chest. Sets `haulerEvacuatingAt`.

These thresholds are evaluated whenever a chest fill event is reported or on a periodic scan.

### 5.3 WebSocket additions

Welcome message gains `role` and `station.name`. New command ops:
- `assignRole` — server tells turtle its role (delivered on next welcome or as command).
- `shaftGranted` / `shaftReleased` — queuing signals.

### 5.3 UI additions (React/Vite, `console/web/src/`)

1. **Pending Roles panel** (Command deck or new "Deployment" tab): table of unassigned turtles with a `Select role` dropdown (station_builder / miner / hauler) and an Assign button.
2. **Station view** (new tab or within Fleet): per-station card showing name, built status, shaft pose, room pose, chest map (33 storage + refuel + depot + fuel), chest IDs, fill levels.
3. **Item request form**: operator enters item name + count + target station → creates request → hauler sees it.
4. **Shaft queue status**: per station, who holds the shaft, who is waiting, estimated wait.
5. **Fleet tab**: filter by `station_builder` and `hauler` roles (already partially exists for hauler as "not wired").

### 5.4 Registry changes (`console/src/registry.ts`)

- Add `station_builder` to valid roles.
- Auto-generate station name on registration: e.g. `Station ${greekOrAlpha[index]}` (Alpha, Bravo, Charlie...). Must be unique.
- `nextStationIndex()` already exists; reuse for name generation.

---

## 6. Turtle Runtime Changes (Lua)

### 6.1 Installer (`mine/install.lua`)

The installer **blocks everything** until role setup succeeds:

1. Checks that HTTP is enabled.
2. Reads `/ccutil/identity.json` if it exists. Otherwise generates 48 hex characters, takes the first 16 as the turtle id and the remaining 32 as the secret. No id is hardcoded.
3. Reads the tunnel URL from `tunnel.json`, or accepts `--url <https://...>`.
4. Registers at `POST /api/register` with id, secret, computer id, label, and installer version.
5. **Blocks**: POST `POST /api/turtles/<id>/role-request` with `{ computerId, label }`. The installer does not proceed to download/reboot until the console assigns a role via `POST /api/turtles/<id>/assign-role`. The turtle waits on this prompt (re-polling the pending-role endpoint) until the operator selects `station_builder`, `miner`, or `hauler`.
6. Saves `/ccutil/identity.json` and `/ccutil/id` including the assigned role.
7. Downloads the runtime manifest and every listed asset (including `station_builder.lua` and `hauler.lua`).
8. Backs up a non-cc-util `/startup.lua` to `/startup.lua.bak` once.
9. Writes `/startup.lua` to run `/ccutil/main.lua`.
10. Reboots after 3 seconds.

If the turtle reboots before a role is assigned, it boots with role `unassigned` and the supervisor waits for an `assignRole` command from the console (the prompt remains blocking until resolved).

### 6.2 Startup / module dispatch (`mine/main.lua` or `mine/lib/supervisor.lua`)

On boot, read role from identity / welcome / pending file. Dispatch:

```lua
local role = identity.role or "unassigned"
if role == "station_builder" then
  require("lib.station_builder").run(id, bus)
elseif role == "hauler" then
  require("lib.hauler").run(id, bus)
elseif role == "miner" then
  require("lib.miner").run(mission, bus)  -- existing, extended for station selection
else
  -- unassigned: wait for assignRole command, then reboot or hot-switch
end
```

GPS failure handling: if `station_builder` (or any GPS-dependent role) cannot sync GPS at startup, it sends `gps-alert` to the console and parks. On `POST /api/stations/<stationId>/reload` from the console, the turtle reboots or re-runs startup and re-attempts GPS sync.
```

### 6.3 New module: `mine/lib/station_builder.lua`

Responsibilities:

1. **GPS sync at startup** — `gps.syncPose` to get absolute world position.
   - **If GPS is unavailable**: the turtle sends `POST /api/stations/<stationId>/gps-alert` to the console. The console shows an attention notification telling the player to build more GPS hosts / fix GPS coverage. The turtle parks and waits. When the operator triggers `POST /api/stations/<stationId>/reload` (reload from console), the turtle re-attempts GPS sync and resumes. It does not proceed blindly without GPS.
2. **Surface chest verification** — expect two chests adjacent to spawn: front (fuel) and back (depot). Use `inspect` to confirm chest presence. Log to console.
3. **Mine shaft down to Y10** — dig 1×1 column from surface to Y10, placing torches or leaving open. Log progress.
4. **At Y10: dig 10×10 room** — clear the room volume. Log when complete.
5. **Place 33 chests** — accessible pattern (see §8.1): 32 storage chests + 1 refueling chest.
   - 32 storage chests: IDs `s<station>-c001` … `s<station>-c032`, kind `storage`. Made for miners to deposit ores/blocks directly.
   - 1 refueling chest: ID `s<station>-c-refuel`, kind `refuel`, adjacent to downward shaft at Y10.
   - Each chest position recorded as world Pose (GPS), registered with console via `POST /api/chests` (or WebSocket message), position + ID logged to console.
   - **Inventory**: 33 chests fit in the turtle's inventory across the build. Fuel is **not** carried during chest placement; once the station is finished and the builder transitions to hauler, it makes a separate trip for fuel (from the surface fuel chest).
6. **Transition to hauler** — when all chests placed and confirmed, update own role to `hauler` on console (`POST /api/turtles/<id>/assign-role` with `hauler`), then load hauler runtime (or reboot so main.lua dispatches to hauler).

### 6.4 New module: `mine/lib/hauler.lua`

Two jobs:

**Job A — Deliver player-requested items up:**
- Console creates `ItemRequest` (item name, count, station).
- Hauler polls `/api/requests` or receives WebSocket command.
- Hauler acquires shaft lock, descends to underground storage, finds chest(s) containing requested item, sucks items, ascends, deposits into surface depot chest.
- Marks request `delivered`, releases shaft lock.

**Job B — Move items up when storage nears capacity (3.5/4 threshold):**
- When `storageChestsFilled` reaches **28/32 (3.5/4)**, the console instructs the station's hauler to begin moving items up from underground storage chests to the surface depot chest.
- Hauler cycles through storage chests, sucks items, ascends, deposits into surface depot, releases shaft lock, repeats until storage is below threshold or all requested items moved.

**Job C — Deliver fuel down to miners:**
- Hauler monitors refueling chest level or responds to miner low-fuel signal.
- Hauler acquires shaft lock, descends, deposits lava buckets into refueling chest near shaft.
- **Fuel**: one lava bucket = 1,000 fuel to a turtle. Empty buckets can be discarded (thrown off) after use.
- Releases shaft lock.

Hauler uses GPS + tape for navigation, same as miner, but its route is: surface depot → shaft → underground chest → shaft → surface depot (or fuel chest variant).

### 6.5 Miner extension (`mine/lib/miner.lua`)

Existing miner already branch-mines. Changes needed:

- **Station selection:** installer or first hello includes `stationId`. Miner builds mission spec for that station's anchor and sector (server already computes sector per station in `mission.ts`).
- **Shaft access:** before descending, miner calls `POST /api/shaft/<stationId>/acquire`. If queued, waits and retries. On completion/abort, calls `release`.
- **Direct ore deposit (no surface transfer):** miners deposit mined ores/blocks directly into underground storage chests at the shaft bottom (Y10), not at the surface. The 32 storage chests exist for this purpose. Miner uses a round-robin or least-full strategy to pick a storage chest, drops items there.
- **Fuel source:** miner refuels from the underground refueling chest at the shaft bottom (hauler-maintained), sucking lava buckets. One lava bucket = 1,000 fuel; empty buckets can be discarded. Falls back to surface fuel chest only if underground refueling chest is empty.
- **Chest fill reporting:** when a miner deposits into a storage chest, it reports the chest's estimated fill level to the console, which updates `storageChestsFilled` and evaluates the 3/4 and 3.5/4 thresholds.

---

## 7. Queuing System (one shaft per station)

### 7.1 Problem

One vertical shaft per station. Turtles (miners, haulers, station builder during construction) all need to traverse it. Two turtles in the same 1×1 shaft at once is impossible in Minecraft (they occupy the same block). Even in a large station, only one turtle can be in the shaft column at a time.

### 7.2 Design: server-managed mutex with FIFO queue

State per station (`ShaftLock`):

- `holderTurtleId`: turtle currently inside the shaft column, or `null`.
- `queue`: ordered array of waiting turtle ids.
- `expiresAt`: absolute deadline; if holder doesn't release before this, server force-releases (fault).

Protocol:

1. Turtle wants shaft access → `POST /api/shaft/<stationId>/acquire` with `{ turtleId, purpose }`.
2. Server checks:
   - If no holder and queue empty → grant immediately, set holder, `acquiredAt = now`, `expiresAt = now + SHAFT_TTL` (e.g. 300 s).
   - Else → append turtleId to queue, return `queued` with position.
3. Turtle polls `GET /api/shaft/<stationId>/status` (or waits on WebSocket `shaftGranted`) until it is the holder.
4. Turtle does its shaft work (descend, work, ascend).
5. Turtle calls `POST /api/shaft/<stationId>/release`.
6. Server clears holder, pops next from queue, sends `shaftGranted` to that turtle (WebSocket), sets new holder + expiry.

### 7.3 Client-side (turtle)

Module `mine/lib/shaft.lua` (or integrated into link):

```lua
function shaft.acquire(stationId, purpose)
  -- POST acquire; if queued, poll status until granted
  -- on success return true
end

function shaft.release(stationId)
  -- POST release
end
```

### 7.4 Safety / deadlock handling

- **TTL auto-release:** if holder crashes or goes stale, server force-releases after `SHAFT_TTL`. Next in queue is granted.
- **Stale detection:** if holder's WebSocket disconnects and `STALE_MS` elapses, server treats as released.
- **Max queue length:** cap (e.g. 8). Reject beyond cap with `rejected`; turtle retries later.
- **Priority:** station builder during construction gets priority over miners/haulers (configurable).

### 7.5 Console visibility

Shaft status shown per station: holder, queue length, wait times, recent acquisitions. Alerts when a lock is held too long (possible stuck turtle).

---

## 8. Chest Placement Pattern (10×10 room, 33 chests, accessible)

This is the hardest part and **must be simulated first** (§9).

### 8.1 Design constraints

- Room is 10×10 at Y10.
- **33 chests total**: 32 storage + 1 refueling.
- Each chest must be reachable: at least one air block adjacent (front/side) for a turtle or player to stand and access.
- "Does not look bad" → orderly grid with aisles, not a random pile.
- Chests are placed by the turtle, so placement order must be a path the turtle can walk without trapping itself.

### 8.2 Proposed pattern (to be simulated)

Use rows with one-block aisles. The exact layout will be finalized in simulation. A candidate pattern fills most of the 10×10 room with chests separated by single-block aisles, leaving the refueling chest adjacent to the shaft.

The final pattern will be encoded as a list of relative offsets in `station_builder.lua`, e.g.:

```lua
local CHEST_LAYOUT = {
  {x=2, z=2, id="s0-c001", kind="storage"}, {x=4, z=2, id="s0-c002", kind="storage"}, ...
  {x=5, z=5, id="s0-c-refuel", kind="refuel"}, -- adjacent to shaft
}
```

### 8.3 Chest registration

Each chest placement sends to console:

```json
{
  "type": "chest_placed",
  "stationId": "s0",
  "chestId": "s0-c017",
  "kind": "storage",
  "pose": { "x": 124, "y": 10, "z": -58, "f": 0 },
  "label": "Storage 17"
}
```

Console stores in `store.data.chests` and broadcasts via Socket.IO. Storage chest IDs run `s<station>-c001`…`s<station>-c032`; refueling chest is `s<station>-c-refuel`.

---

## 9. Simulation Plan (before real deployment)

Per requirement: "we will need to simulate everything inside our environment first once finished one miner setup we will increasing miner population."

### 9.1 Mock environment (extends `mine/test/test.lua`)

Use the existing mock-turtle harness (`lib.hal` with a custom backend) to simulate:

1. **World grid:** 3D array of blocks (air / stone / chest / fuel / ore).
2. **GPS:** mock `gps.locate` returns exact simulated position.
3. **Chest inventory:** each chest has an item map; `suck`/`drop` simulate transfers.
4. **Console API:** mock HTTP endpoints capture `chest_placed`, `request`, `shaft_acquire/release` calls.

### 9.2 Simulation tests

| Test | What it verifies |
|---|---|
| `station_builder: chest pattern fits 10×10` | All 32 storage + 1 refuel chest fit without overlap, each has air access. |
| `station_builder: placement path` | Turtle can walk to every chest position without trapping itself. |
| `station_builder: Y10 shaft` | Shaft descends correctly from surface to Y10. |
| `station_builder: GPS unavailable` | Turtle sends gps-alert, parks, waits for console reload, then resumes. |
| `hauler: request fulfillment` | Hauler finds item in storage chest, brings to depot, marks delivered. |
| `hauler: fuel delivery` | Hauler deposits lava into refueling chest; empty buckets discarded. |
| `hauler: move-up at 3.5/4` | At 28/32 filled chests, hauler starts moving items up to surface depot. |
| `shaft queue: mutual exclusion` | Two turtles cannot hold the lock simultaneously; FIFO order respected. |
| `shaft queue: TTL release` | Stale holder is auto-released, next in queue granted. |
| `miner: direct ore deposit` | Miner drops ores into underground storage chest (not surface). |
| `miner: refuel from underground` | Miner sucks lava from refueling chest at shaft bottom. |
| `multi-miner: N miners one shaft` | 2–4 miners serialize shaft access without deadlock. |
| `capacity: 3/4 notification` | At 24/32 filled, console notifies operator to set up surface depot. |
| `role transition: builder→hauler` | Builder completes station, switches to hauler, starts serving requests. |
| `installer: blocking role prompt` | Installer waits until console assigns role before downloading/rebooting. |

### 9.3 Simulation runner

Create `mine/test/simulate.lua` that:
- Spawns N mock turtles with roles.
- Drives them through a full station deployment + mining cycle.
- Asserts invariants: no chest overlap, shaft mutex respected, all requests delivered, fuel chest replenished.

Run with desktop Lua (no Minecraft needed), same as `test.lua`.

---

## 10. Implementation Phases

### Phase 0 — Foundation (data + console endpoints)
1. Add `station_builder` to `TurtleRole` union in `shared/api.ts`.
2. Add `Chest`, `ItemRequest`, `ShaftLock` types to `shared/api.ts`.
3. Extend `StoreData` with `chests`, `requests`, `shaftLocks`; extend `Station` with `name`, `shaftPose`, `roomPose`, `built`.
4. Add HTTP endpoints: role-request, pending, assign-role, chests, requests, shaft acquire/release/status.
5. Add WebSocket command ops: `assignRole`, `shaftGranted`, `shaftReleased`.
6. Console UI: Pending Roles panel, Station view (chest map), Item Request form, Shaft queue status.
7. Typecheck + unit tests for queue logic.

### Phase 1 — Installer + role flow
1. `install.lua`: POST role-request after registration; optional poll; save pending role.
2. `registry.ts`: auto-generate station name; validate `station_builder` role.
3. Test: install a turtle, see it appear in Pending Roles, assign role, verify it's stored.

### Phase 2 — Station builder (Lua)
1. `mine/lib/station_builder.lua`: GPS sync, surface chest check, shaft to Y10, 10×10 dig, 33-chest placement with IDs, refueling chest, chest registration to console.
2. Role transition builder → hauler at completion.
3. Simulation tests in `mine/test/simulate.lua` for chest pattern + placement path.

### Phase 3 — Hauler (Lua)
1. `mine/lib/hauler.lua`: request polling, item retrieval from storage, depot delivery, fuel delivery down, shaft lock usage.
2. Console UI: item request form, request list.
3. Simulation tests: request fulfillment, fuel delivery.

### Phase 4 — Miner + queuing
1. `mine/lib/shaft.lua`: acquire/release/poll client.
2. `mine/lib/miner.lua`: station selection, shaft acquire before descent, refueling chest usage, ore deposit into storage chest.
3. Server: `ShaftLock` state machine, TTL, stale release, WebSocket grant notifications.
4. Simulation: multi-miner one shaft, deadlock freedom.

### Phase 5 — Polish + scale
1. Console: station detail page, chest fill-level indicators, shaft queue history.
2. Increase miner population one station at a time; monitor shaft contention.
3. If queue wait times become a problem, evaluate forward depot at mining depth or second shaft.

---

## 11. Open Questions / Decisions Needed

The following were **resolved** per operator feedback:

- **Miner ore deposit:** miners drop ores/blocks directly into underground storage chests (32 chests made for this). No surface transfer.
- **Chest count:** 32 storage + 1 refueling = 33 underground chests total. Chest IDs are station-scoped: `s<station>-c001`…`s<station>-c032` for storage, `s<station>-c-refuel` for fuel.
- **Capacity thresholds:** 24/32 (3/4) → notify player to set up surface depot; 28/32 (3.5/4) → hauler auto-starts moving items up to surface storage.
- **Fuel:** one lava bucket = 1,000 fuel; empty buckets discarded.
- **Station builder inventory:** 33 chests fit; fuel is a separate trip after builder transitions to hauler.
- **GPS:** if unavailable, turtle sends `gps-alert`, parks, waits for console `reload`; resumes once GPS restored.
- **Console prompt:** installer blocks until role is assigned successfully.

Remaining open questions:

1. **Chest capacity detection:** how does the turtle estimate a chest's fill level? Options: count items via `getItemDetail` when depositing, or hauler inspects on sweeps. Needs a simple heuristic (e.g., slots used / 27).
2. **Surface depot construction:** player builds the surface depot themselves; console just notifies. No turtle automation for depot construction — player places chests manually.
3. **GPS coverage:** how many GPS hosts needed at the station? Turtle needs GPS at surface and ideally at Y10. May need relay hosts underground or dead-reckoning fallback from shaft top.
4. **Hauler move-up scope:** when 3.5/4 threshold is hit, does the hauler move *all* items up or just enough to get below threshold? (Recommended: move enough to get back below 24/32.)
5. **Multiple stations sharing a hauler:** can one hauler serve multiple stations, or one hauler per station? (Recommended: one hauler per station initially, revisit at scale.)

---

## 12. Files to Create / Modify

### Create
- `console/src/shaft.ts` — ShaftLock state machine
- `console/src/chests.ts` — chest registry handlers
- `console/src/requests.ts` — item request handlers
- `mine/lib/station_builder.lua`
- `mine/lib/hauler.lua`
- `mine/lib/shaft.lua` — client-side acquire/release
- `mine/test/simulate.lua` — full-environment simulation
- `STATION_DEPLOYMENT_PLAN.md` (this file)

### Modify
- `console/shared/api.ts` — new types
- `console/src/store.ts` — new collections
- `console/src/registry.ts` — station_builder role, auto station names
- `console/src/http.ts` — new endpoints
- `console/src/hub.ts` — new WebSocket ops, role in welcome
- `console/src/index.ts` — attach new route modules
- `console/web/src/tabs/` — new Deployment/Station views
- `mine/install.lua` — role-request flow
- `mine/main.lua` or `mine/lib/supervisor.lua` — role dispatch
- `mine/lib/miner.lua` — station selection, shaft lock, refueling chest
- `mine/lib/hal.lua` — chest place/suck helpers if needed

---

## 13. Success Criteria

- [ ] Installer triggers a console role-selection prompt for the new turtle and **blocks** until role is assigned successfully.
- [ ] Station builder autonomously: GPS-fixes, checks surface chests, mines shaft to Y10, digs 10×10 room, places **32 numbered storage chests + 1 refueling chest** in accessible pattern, logs all chest positions+IDs to console, sends GPS alert if unavailable, parks and waits for console reload if GPS missing, transitions to hauler when done.
- [ ] Hauler fulfills a player item request (up) and a miner fuel request (down, lava buckets).
- [ ] Hauler auto-starts moving items up to surface depot when storage reaches **28/32 (3.5/4)** filled.
- [ ] Console notifies operator to set up surface depot when storage reaches **24/32 (3/4)** filled.
- [ ] Miner placed at shaft entrance, installed, selects station, descends via shaft lock, deposits ores directly into underground storage chest, refuels from underground refueling chest.
- [ ] No two turtles hold the shaft lock at once (simulated and real).
- [ ] Full cycle simulated in mock Lua before any real turtle deployment.
- [ ] Second miner added to same station without shaft conflict.

---