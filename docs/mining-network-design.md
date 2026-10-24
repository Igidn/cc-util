# CC: Tweaked mining network

A fleet of CC: Tweaked turtles mines disjoint sectors under one external
Node/TypeScript console. Each turtle connects over a single WebSocket, owns its
local safety, and finishes or aborts a trip without further contact. No GPS is
required.

This document describes the code that exists in this repository. It is not a
proposal for a future system. Where the implementation is narrower than the
original design, the limitation is stated in section 17.

## TL;DR

- The server is a dispatcher. It assigns a bounded branch-mine mission and
  renders telemetry. It never sends move commands.
- Safety limits (radius, depth, fuel reserve) are enforced on the turtle, with
  hard caps the server cannot widen.
- The plan is deterministic. Progress is durable. The tape records only the trip
  actually walked and is popped on the way home.
- Fuel is an exact round-trip budget, not an estimate.
- Pose is station-local dead reckoning. Every move is gated, journaled, and
  reconciled on boot with the fuel counter as the witness.
- Each turtle gets its own station, shaft, and sector. There are no shared
  corridors in v1.
- Mining is a sequence of round trips from the dock, not one continuous
  expedition.
- The server persists the mission spec, progress, and a sparse per-station ore
  map. The tunnel cells are derived from the plan, so the full per-block tunnel
  map is reproducible rather than stored.
- GPS is not implemented. The dock is the calibration source.

## 1. Repository layout

```
console/                 Node 20+ / TypeScript console
  src/config.ts          env configuration and mine geometry
  src/types.ts           protocol and store types
  src/store.ts           JSON state store with atomic writes
  src/plan.ts            TypeScript copy of the deterministic plan
  src/mission.ts         mission spec creation and progress summary
  src/map.ts             derived tunnel cells plus saved ore cells
  src/registry.ts        registration, secret hashing, station assignment
  src/hub.ts             WebSocket auth, missions, telemetry, control
  src/http.ts            dashboard, registration, state, map, control
  src/tunnel.ts          OpenTunnel route add / status
  src/publish.ts         runtime manifest and fixed-tag GitHub release
  src/index.ts           startup and shutdown

mine/                    CC: Tweaked Lua runtime
  install.lua            starter installer
  main.lua               entry point, link + supervisor in parallel
  lib/identity.lua       /ccutil/identity.json
  lib/hal.lua            mockable turtle API
  lib/pose.lua           pose and facing arithmetic
  lib/tape.lua           per-trip op stack
  lib/plan.lua           plan builder, validation, progress
  lib/safety.lua         fuel invariant
  lib/state.lua          checkpoint + append-only journal
  lib/nav.lua            gated movement and retrace
  lib/dock.lua           physical re-zero fixture
  lib/resolve.lua        tunnel address from the GitHub release
  lib/link.lua           WebSocket, outbox, tunnel refresh
  lib/miner.lua          trip executor
  lib/supervisor.lua     mission loop and pause/halt state
  test/test.lua          20 offline tests with a mock turtle

docs/                    this document
```

The console is not hosted on the Minecraft server. It runs on a separate Node
process and reaches the turtles through the OpenTunnel public URL.

## 2. Boundary between server and turtle

| Layer | Owns | Runs on |
|---|---|---|
| Console | registration, stations, mission specs, progress, ore map, dashboard, tunnel publication | Node/TS |
| Turtle | pose, plan validation, fuel, movement, mining, journal, recovery | CC: Tweaked Lua |
| Transport | one WebSocket per turtle, JSON, protocol version 1 | `http.websocket` |

The command protocol supports `startMission`, `abort`, `returnHome`, and
`ping`; the console uses the first three. It does not send `forward`, `dig`, or
any other movement. A command round trip is 50 to 500 ms and can fail
completely, so the control loop stays on the turtle.

The turtle expands the mission spec into the same deterministic plan the server
uses, validates it against local hard caps, and executes one trip at a time. If
the socket dies mid-tunnel, it keeps working and returns home. If the server
sends a malformed spec, the turtle refuses it.

## 3. Coordinates, dock, and re-zero

Coordinates are station-local:

- `+X` east, `+Z` south, `+Y` up.
- Facing `f` in `{0,1,2,3}` is north (-Z), east (+X), south (+Z), west (-X).
- `pose = {x, y, z, f}`.
- The dock is `{0, 0, 0, 0}` in every station frame.

The server stores a world anchor per station for the dashboard, but the turtle
never uses world coordinates. Telemetry is station-local.

### 3.1 Dock fixture

The turtle stands on the output chest. The shaft is one block north. The rear
wall is south. The left wall is west. The fuel chest is above.

```
                 fuel chest (0, 1, 0)
                        |
   west wall (-1,0,0)   T (0,0,0)   north: shaft top (0,0,-1)
                        |
                 output chest (0,-1,0)

   rear wall (0,0,1)    [south]
```

The turtle faces north at the end of every re-zero. The output chest is a solid
floor. The fuel chest sits above the turtle so `suckUp` can refuel without
turning. The shaft top is air; the plan's staging leg steps into it.

The re-zero sequence is:

1. `down()` until blocked. That is the floor. Set `y = 0`.
2. `back()` until blocked. That is the rear wall.
3. `turnLeft()`, then `forward()` until blocked. That is the west wall.
4. `turnRight()`. Set `pose = {0,0,0,0}`.

The raw moves are bounded to 5 blocks. If a fixture is missing, `dock.zero`
returns an error and the trip fails. It does not guess. Fuel errors during the
re-zero are fatal for the same reason: the turtle cannot safely return without a
known position.

The re-zero runs at the start of every trip and after every return. Pose error
therefore does not accumulate across trips.

### 3.2 Staging

The plan starts with a north line of length `staging`, default 1. That moves the
turtle from the dock into the shaft top. The shaft is one block north of the
dock, so the sector's z range is shifted by `-staging`.

The staging leg is part of the plan and part of the trip tape. The turtle
returns through it like any other leg.

## 4. Depth, sector size, and scale

Defaults in `console/src/config.ts`:

| Setting | Default | Meaning |
|---|---|---|
| `BASE_Y` | 10 | station anchor Y, where the dock is built |
| `TOP_WORLD_Y` | 0 | top of the mined layers |
| `BOTTOM_WORLD_Y` | -58 | bottom of the mined layers |
| `LAYER_STEP` | 2 | descent between layers |
| `BRANCH_SPACING` | 3 | z distance between strips |
| `SECTOR_HALF` | 48 | half-width of the square sector |
| `MAX_RADIUS` | 128 | turtle hard cap |
| `MAX_DEPTH` | 200 | turtle hard cap |
| `RESERVE` | 64 | fuel kept for the return |
| `MAX_TRIP_BLOCKS` | 240 | new blocks per trip |
| `MAX_VEIN_BLOCKS` | 24 | ore detour cap |
| `STATION_SPACING` | 256 | world x distance between stations |

The mission computes local Y as:

```
startY = TOP_WORLD_Y - anchor.y = 0 - 10 = -10
endY   = BOTTOM_WORLD_Y - anchor.y = -58 - 10 = -68
```

The shaft descends 10 blocks from the dock at world Y=10 to world Y=0. The first
layer is at world Y=0. Layers step down 2 blocks to world Y=-58, which is local
Y=-68. That is 30 layers.

The starting terrain in the modded world is around Y=800. The dock at Y=10 and
the mine at Y=0 to -58 avoid it entirely.

### 4.1 Sector size and the 8-chunk question

The client render distance is not the tick distance. The server's simulation
distance and view distance decide which chunks tick. A square sector of half
`h` fits inside a loaded circle of radius `r` when `h <= floor(r / sqrt(2))`.
For 8 chunks, `r = 8 * 16 = 128`, so the safe square half is 90. That is why
`MAX_RADIUS` is 128 but the default `SECTOR_HALF` is 48.

Plan block counts for the default 30 layers and spacing 3:

| Half | Strips per layer | Plan blocks | Approx. trips at 240 new blocks |
|---|---|---|---|
| 48 | 33 | 98,085 | 409 plus travel |
| 90 | 61 | 335,000 | 1,400 plus travel |
| 128 | 86 | 668,000 | 2,800 plus travel |

Travel dominates these numbers. Each trip starts at the surface dock, replays
the plan to the frontier, mines up to 240 blocks, and returns. A forward depot
at mining depth would cut the travel cost, but it is not implemented. Use the 48
pilot sector first. Section 17 lists the scale decision.

The server clamps `SECTOR_HALF` to `MAX_RADIUS` before creating a mission, so a
configuration mistake cannot hand the turtle a sector it will reject.

## 5. The deterministic plan

`mine/lib/plan.lua` and `console/src/plan.ts` implement the same geometry. They
must stay in sync; the Lua test suite checks the geometry and continuity.

A leg is a straight run:

```lua
{ kind = "line" | "down", dir = 0..3, length = n, layer = l, strip = s }
```

The plan is built in this order:

1. Staging north, length `staging`.
2. Shaft down, length `-startY`.
3. West to the sector's -X edge, length `half`.
4. North to the sector's -Z edge, length `half`.
5. For each layer: east/west strips of length `2*half`, connected by
   north/south legs of length `spacing`.
6. Between layers: down `layerStep`.

The number of strips is `floor(2*half/spacing) + 1`. With half 48 and spacing 3
that is 33 strips, 96 blocks long, with 2-block pillars. The strip direction
alternates, so the path is continuous. The z direction also alternates between
layers. The layer transition drops at the end of the last strip, so the next
layer starts at the same x edge.

Progress is `{leg, offset, layer, strip}`. `leg` is 1-based. `offset` is the
number of blocks already walked in that leg. `plan.normalize` advances past
complete legs and returns true when the plan is done.

A single-layer mission (`startY == endY`) is valid. The turtle validation rejects
`endY > startY`, not equality.

Validation on the turtle (`plan.validate`) checks:

- kind is `branchMine`
- base pose exists
- `startY <= 0` and `endY <= startY`
- radius is at least 4 and at most the local hard cap
- staging is 0 to 4
- depth is at most 200
- layer step is at least 1
- spacing is at least 2
- trip budget is at least 1
- vein cap is at least 0
- reserve is at least 0

The miner also clamps trip budget, vein cap, and reserve to local maxima and a
minimum reserve of 16 before building the plan.

## 6. Trips, tape, journal, and recovery

### 6.1 The per-trip tape

The tape is a stack of operations actually walked during one trip. It starts
empty at the dock. The travel replay and the mining push translations and turns.
The return pops the stack and applies the inverse of each op.

- `F/B/U/D` are translations and cost one fuel each.
- `TL/TR` are turns and cost nothing, but they are recorded because `back()` is
  relative to the current facing.
- The return cost is the number of translations currently on the tape. That is
  an exact fuel requirement.
- Replaying to the frontier is safe because the turtle dug those tunnels itself.

The plan is durable. The tape is not. It is persisted only while `tripActive` is
true, together with the pose and journal, so a reboot can retrace it. After a
successful return the tape is empty and the plan progress is the durable state.

Ore detours use a temporary suffix. The miner records `detourBase`, walks the
vein, returns to that base, and truncates the suffix. The main tape is left
untouched.

### 6.2 The journal and checkpoint

`/ccutil/state.json` is the checkpoint. `/ccutil/journal.log` is the
append-only journal.

Each translation is written twice:

```
I <seq> move forward 812
C <seq> forward
```

A retrace is written as:

```
I <seq> retrace back 811
R <seq> back
```

A failed move writes `F <seq>`.

The checkpoint contains the mission id and spec, progress, `tripActive`, pose,
tape, stats, journal sequence, and the `paused` and `halted` flags. It is
written atomically through a temp file and rename. After a checkpoint, the
journal is truncated. If truncation is interrupted, old journal lines are
ignored because their sequence is at or below the checkpoint's sequence.

### 6.3 Boot recovery

`state.load` replays the journal tail over the checkpoint. A trailing intent with
no commit is resolved with the fuel counter:

- A successful translation spends exactly one fuel. If fuel is one lower, the
  move happened. If it is unchanged, the move did not happen.
- Turns have no fuel witness. An unresolved turn intent is assumed successful
  and the recovery is marked uncertain.
- With unlimited fuel there is no witness. A translation intent is assumed
  successful and marked uncertain.

The miner then:

1. If `tripActive` and the tape is non-empty, retrace the tape to the dock. If
   that fails, send `recovery_failed`, report a failed mission, and wait for a
   human. It does not improvise a new route.
2. Re-zero at the dock and unload/refuel.
3. Resume from the last checkpointed plan progress. Mid-trip resume in place is
   not attempted; re-walking an already-mined tunnel is cheap, and reconciling
   a half-executed plan is not.

The uncertain flag is logged. It does not change the route; the tape retrace is
still the best available information.

### 6.4 A trip

Each trip is bounded by fuel, inventory, `maxTripBlocks`, and the plan. The
executor:

1. Re-zero at the dock.
2. Save a checkpoint with `tripActive = true` and a fresh tape.
3. Replay the plan from the start to the saved progress. Already-mined blocks
   are air.
4. Mine up to `maxTripBlocks` new blocks, with bounded vein detours.
5. Check the fuel margin and inventory before each block.
6. Pop the tape all the way home.
7. Unload into the output chest and refuel from the fuel chest.
8. Save a checkpoint with `tripActive = false` and report progress.

A trip that mines zero new blocks returns a failed mission with
`no progress this trip (fuel or inventory)`. That usually means the output chest
is full, the fuel chest is empty, or the turtle cannot reach the frontier.

## 7. Fuel

Movement costs one fuel per block. Turns, digging, inspecting, and dropping are
free. `turtle.getFuelLevel()` returns a number or the string `"unlimited"`.

`safety.lua` enforces three checks:

```lua
-- A new translation. cost is the current return cost.
fuel - 1 >= cost + 1 + reserve

-- A retrace. cost includes the op being popped.
fuel - 1 >= cost - 1 + reserve

-- A turn. cost is unchanged.
fuel >= cost + reserve
```

`shouldEndTrip` stops the trip when the remaining fuel above the reserve falls
to 4 on a normal block or 8 during a vein detour.

The reserve default is 64. The dock re-zero is outside the tape and has its own
bounded raw moves; the reserve covers it.

At the dock the turtle:

- unloads everything except the selected fuel slot,
- pulls up to 16 stacks from the chest above with `suckUp`,
- refuels from inventory.

`hal.findFuelSlot` recognizes coal, charcoal, coal blocks, blaze rods, lava
buckets, and dried kelp blocks. Modded fuels need to be added there. The fuel
chest should contain fuel only. If it contains ore or stone, the turtle pulls it
into the inventory and the next trip may fail the inventory check.

## 8. Ore policy and the saved map

At each mined block the turtle inspects the six neighbours. Inspecting is free.
It recognizes:

- `c:ores` and `forge:ores` tags,
- a name ending in `_ore`,
- `minecraft:ancient_debris`.

Vein mining is a bounded depth-first search over ore-tagged neighbours:

- cap at `maxVeinBlocks`, default 24,
- never enter lava, fire, or unbreakable blocks,
- record the detour on the tape,
- stop the detour when the fuel margin is 8,
- return to the detour base and truncate the suffix.

Without the cap, one vein can consume the trip. With it, the vein is a bonus.

When an ore is mined, the turtle sends:

```json
{"type":"event","kind":"ore","data":{"x":-3,"y":-12,"z":-4,"name":"minecraft:diamond_ore"}}
```

The console stores it in `StoreData.maps[stationId].ores`, keyed by
`x,y,z`. This is the durable sparse map.

The full tunnel map is not stored. The mission spec and progress are enough to
rebuild the tunnel cells deterministically:

```
GET /api/map?missionId=<id>
```

returns the mission state, progress, spec, derived tunnel cells up to that
progress, and the station's ore cells. The counts are included for convenience.
The dashboard links to this endpoint from each mission row.

This design saves the mined map in two parts: the deterministic tunnel cells,
which are reproducible, and the ore cells, which are not. Vein detour tunnels
that contain no ore are not represented. If a full voxel map is needed later,
the store can add a per-block tunnel set without changing the turtle protocol.

## 9. Stations and multiple turtles

Registration assigns the lowest free station index. The station anchor is:

```
x = BASE_X + index * STATION_SPACING
y = BASE_Y
z = BASE_Z
```

Each turtle owns one station, one shaft, and one square sector. Sectors are
disjoint because the station spacing is larger than the sector width. There are
no shared corridors, so v1 has no traffic coordination.

There is no lease and no TTL in v1. A mission belongs to one turtle until it is
done or failed. A stale turtle is marked `stale` after `STALE_MS` without a
heartbeat; its mission is not expired. A human can start, abort, or return it
from the dashboard.

A lost turtle's station is not reassigned. The turtle id and station id persist.
The operator can inspect the dashboard, rescue the turtle, or start a new
mission on the same station. Re-mining a sector is possible: the old tunnels are
air, the remaining ores are still there, and the plan is deterministic.

`STATION_SPACING` must be larger than `2 * SECTOR_HALF + margin`. The default
256 is comfortable for half 48. If the sector half is raised toward 128, raise
the spacing too.

## 10. Chunk loading

Turtles tick only in loaded chunks. A turtle far from every player freezes, and
depending on the server it may come back with a fresh boot. The local checkpoint
and journal exist for that case.

Options:

- keep the mine inside spawn chunks,
- run a chunk loader,
- keep a player nearby during testing.

The server distinguishes `stale` (no heartbeat) from `halted` or `paused` (the
turtle reported a state). It does not expire a stale mission. The heartbeat
interval is 5 seconds and the stale timeout is 20 seconds by default.

The server's simulation distance and view distance control ticking. The client
render distance does not. The 8-chunk radius in the requirements is a planning
number, not a guarantee that the whole sector ticks.

## 11. Transport and protocol

One WebSocket per turtle at `wss://<tunnel-host>/ws`, JSON, protocol version 1.
The `hello` must arrive within 10 seconds. Authentication is the turtle id plus
secret; the server stores a SHA-256 hash of the secret.

### 11.1 Messages

Hello:

```json
{"v":1,"type":"hello","id":"a1b2c3d4e5f60718",
 "secret":"<32 hex>","computerId":12,"label":"miner-1","fw":"0.1.0",
 "pose":{"x":0,"y":0,"z":0,"f":0},"fuel":980,
 "inventory":[],"state":"idle","missionId":null}
```

Welcome:

```json
{"v":1,"type":"welcome","turtleId":"a1b2c3d4e5f60718",
 "station":{"id":"s0","index":0,"anchor":{"x":0,"y":10,"z":0}},
 "config":{"reserve":64,"maxTripBlocks":240,"maxVeinBlocks":24,
           "maxRadius":128,"maxDepth":200,"heartbeatMs":5000},
 "serverTime":1730000000000,
 "mission":null}
```

Command:

```json
{"v":1,"type":"command","id":"<uuid>","seq":17,"op":"startMission",
 "mission":{"id":"<uuid>","spec":{...}}}
```

The other ops are `abort`, `returnHome`, and `ping`. The turtle acks with
`{"type":"ack","id":"<uuid>","status":"started"}`. A duplicate start for the
mission already running acks `already-running`; it does not restart work.

Progress:

```json
{"type":"progress","missionId":"<uuid>",
 "progress":{"leg":14,"offset":37,"layer":2,"strip":5},
 "pose":{"x":-3,"y":-12,"z":-4,"f":1},"fuel":812,
 "inventory":[{"slot":1,"name":"minecraft:coal","count":32}],
 "state":"mining","stats":{"blocks":37,"ores":2,"trips":1}}
```

Result:

```json
{"type":"result","id":"<uuid>","missionId":"<uuid>",
 "status":"done","error":null,
 "stats":{"blocks":240,"ores":7,"trips":1},
 "progress":{"leg":14,"offset":37,"layer":2,"strip":5}}
```

The status is `done`, `paused`, or `failed`. `returnHome` produces `paused`.
`abort` produces `failed`. A local fault produces `failed` with an error string.

Heartbeat:

```json
{"type":"heartbeat","pose":{...},"fuel":812,"inventory":[...],
 "state":"mining","missionId":"<uuid>"}
```

The link reconnects forever with exponential backoff capped at 30 seconds. It
queues outbound messages while offline, up to 200. It refreshes the tunnel
address after three consecutive WebSocket failures. The tunnel resolver caches
the URL for 10 minutes and falls back to the last known URL if GitHub is
unavailable.

The server retries an unacked command once, after 8 seconds, then drops it. It
also closes a connection that has not sent a heartbeat within `STALE_MS`.

Late messages are guarded by mission id and state. A progress for a done,
failed, or paused mission does not reactivate it, and a result for a done or
failed mission is ignored. A result for a mission that is no longer current
updates that mission but leaves the turtle's current mission id alone. This
matters because the outbox can deliver a result for the previous mission after
a new mission has started.

### 11.2 Mission lifecycle

The server creates a mission in `offered`. When a turtle connects:

- If it has an active or offered mission, the welcome includes it and the server
  re-sends `startMission`.
- If it has no mission and no mission history, the server creates and starts the
  first mission automatically.
- If it has no mission but has history, the server waits for the dashboard
  start. This is the rule after a done or failed mission.
- If the mission is paused, the server does not offer it. The dashboard start
  resumes it.
- If the turtle reports `paused` or `halted` in its hello, the server does not
  re-offer an active mission. The local state wins until an explicit start.

`returnHome` pauses the mission. The turtle returns to the dock, sets its local
`paused` flag, and reports `paused`. A reboot does not auto-resume a paused
mission; the supervisor waits for a start command.

`abort` fails the mission. The turtle still returns home first, sets its local
`halted` flag, and reports `failed`. If the mission is already paused or offered,
the server fails it immediately because there is no running trip to recall.

A start command is the operator's explicit resume. It clears the local paused or
halted flags in the miner. A start command that arrives while the previous
mission is winding down is queued, not dropped.

## 12. Console server

The console uses Node, TypeScript, `ws`, and a JSON file. There is no database.

`console/data/state.json` holds:

```ts
{
  version: 1,
  turtles:  { [id]: Turtle },
  stations: { [id]: Station },
  missions: { [id]: Mission },
  events:   EventRecord[],   // capped at 5000
  maps:     { [stationId]: { ores: { [x,y,z]: OreCell } } }
}
```

Writes are debounced by 100 ms and use a temp file plus rename. The process
flushes on SIGINT and SIGTERM.

### 12.1 Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/` | none | dashboard |
| GET | `/api/health` | none | liveness |
| GET | `/api/tunnel` | none | current public URL |
| POST | `/api/register` | none | create or re-authenticate a turtle |
| GET | `/api/state` | admin | turtles, stations, missions, events |
| GET | `/api/map?missionId=` | admin | derived tunnel cells plus ore cells |
| POST | `/api/turtles/<id>/start` | admin | create or resume a mission |
| POST | `/api/turtles/<id>/return` | admin | pause and return home |
| POST | `/api/turtles/<id>/abort` | admin | fail the mission |

Admin authentication is `Authorization: Bearer <ADMIN_TOKEN>` or
`?token=<ADMIN_TOKEN>`. If `ADMIN_TOKEN` is empty, every endpoint is open to
anyone with the tunnel URL. That is acceptable for a local pilot and not
acceptable for a public server.

Registration is open by design. It requires a 16 to 64 character hex id and a 32
to 128 character hex secret. A re-registration with the same id must present the
same secret. The server hashes the secret with SHA-256 before storing it.

### 12.2 Dashboard

The dashboard shows the tunnel URL, each turtle's label, id, station, state,
pose, fuel, mission state, progress bar, map link, and start/return/abort
buttons. It polls `/api/state` every 2 seconds. The event log shows the last 12
events.

The progress bar uses the server-computed `percent`, which is the number of plan
blocks completed divided by the plan total. It is not a per-trip counter.

## 13. Installer and release publishing

### 13.1 Console startup

`console/src/index.ts` does this:

1. Start the HTTP server and WebSocket hub.
2. Resolve the public tunnel. `PUBLIC_URL` wins. Otherwise the console runs
   `opentunnel route add <PORT>` and parses the `https://...` URL. If that fails,
   it runs `opentunnel status`.
3. Write `tunnel.json`, `manifest.json`, `install.lua`, and the flat runtime
   assets under `console/.runtime/`.
4. If `PUBLISH=1` (the default), upload those files to the fixed GitHub release
   tag `tunnel-latest` with `gh release upload --clobber`.
5. Print the turtle install command.

The fixed tag matters. A later code release must not change the URL the turtles
use:

```
https://github.com/Igidn/cc-util/releases/download/tunnel-latest/tunnel.json
```

Release assets are flat because GitHub release asset names cannot contain
slashes. `manifest.json` maps each flat asset back to its runtime path:

```json
{"version":"...","generatedAt":1730000000000,
 "files":[{"path":"lib/tape.lua","asset":"lib__tape.lua"}]}
```

`PUBLISH=0` writes the runtime locally and skips GitHub. This is what the smoke
test uses.

### 13.2 Installer

Run on a turtle:

```
wget https://github.com/Igidn/cc-util/releases/download/tunnel-latest/install.lua install.lua
install
```

The installer:

1. Checks that HTTP is enabled.
2. Reads `/ccutil/identity.json` if it exists. Otherwise it generates 48 hex
   characters, takes the first 16 as the turtle id and the remaining 32 as the
   secret. No id is hardcoded.
3. Reads the tunnel URL from `tunnel.json`, or accepts `--url <https://...>`.
4. Registers at `POST /api/register` with id, secret, computer id, label, and
   installer version.
5. Saves `/ccutil/identity.json` and `/ccutil/id`.
6. Downloads `manifest.json` and every listed asset into `/ccutil/<path>`.
7. Backs up a non-cc-util `/startup.lua` to `/startup.lua.bak` once.
8. Writes `/startup.lua` to run `/ccutil/main.lua`.
9. Reboots after 3 seconds.

A reinstall reuses the identity. Delete `/ccutil/identity.json` only if the
turtle should get a new station. The old station and its ore map stay on the
server.

The installer's random source is CC's `math.random`, seeded from the computer id
and the millisecond clock. The id and secret are generated in one call, so the
secret is not a repeat of the id. This is adequate for a private server and a
tunnel, not for a hostile public service.

### 13.3 Turtle HTTP allowlist

CC: Tweaked must be allowed to reach:

- `github.com` for the release asset URLs,
- `objects.githubusercontent.com` for the release redirect,
- the OpenTunnel host for `/api/register` and `/ws`.

The simplest private setup is `http.enabled=true` with the default allowlist, or
`http.whitelist=*` on a server you control. The WebSocket uses the same HTTP
permission. If the release redirect is blocked, the installer and tunnel
resolver fail with an HTTP error.

## 14. Failure handling

| Symptom | Detection | Response |
|---|---|---|
| Fuel below reserve | invariant | end trip, return, dock, refuel |
| Inventory nearly full | slot count >= 15 | end trip, return, unload |
| Block obstructs a tunnel | `forward` false | abort the trip, return, report |
| Unbreakable block | `dig` false | abort the trip, return, report |
| Lava or fire ahead | `inspect` tags/name | abort the trip, return, report |
| Entity blocking | `forward` false | abort the trip, return, report |
| Socket down | send/receive failure | keep mining, queue up to 200, reconnect |
| Server down for long | silence | finish the trip, dock, park |
| Ambiguous boot | trailing intent | fuel witness, uncertain turn, retrace |
| Dock damaged | re-zero fails | fault, do not move |
| Turtle lost | heartbeat stale | mark stale, keep mission, human rescue |
| Paused or halted reboot | local flags | do not auto-resume, wait for start |
| Result or progress delayed | mission id/state guard | ignore, do not resurrect |

The rule is to fail toward the dock. The turtle does not improvise a new route.
A deterministic plan with a recorded tape is recoverable; on-the-fly pathfinding
inside a live tunnel is not.

## 15. Tests and smoke test

The Lua tests run on desktop Lua 5.1+ without Minecraft:

```
find mine -name '*.lua' -print0 | xargs -0 -n1 luac -p
lua mine/test/test.lua
```

The suite has 20 tests and uses a mock turtle backend. It covers pose and facing
arithmetic, tape push/pop and cost, plan geometry and continuity, plan
validation, the fuel invariant at the reserve boundary, journal replay with and
without a fuel witness, interrupted turns and retraces, a full small mission
through the real miner/nav/state with a mock turtle, and pause/halt persistence.

The TypeScript console typechecks with:

```
cd console
npx tsc --noEmit -p tsconfig.json
```

The console smoke test uses a temp data directory and disables publishing:

```
PUBLISH=0 PORT=3100 PUBLIC_URL=http://127.0.0.1:3100 \
  DATA_DIR=/tmp/cc-util-smoke/data \
  RUNTIME_DIR=/tmp/cc-util-smoke/runtime \
  npx tsx src/index.ts
```

The smoke test exercises:

- `/api/health`
- `/api/register`
- `/api/state`
- a WebSocket hello, welcome, startMission, ack, progress, result
- the dashboard start after a done mission
- `/api/map` derived cells and an ore event

The map test sends an `ore` event and verifies that the ore appears in
`state.json` and in the map response.

## 16. Current status and build order

Implemented:

1. HAL, mock simulator, pose, tape, plan, fuel invariant, dock re-zero.
2. One-turtle trip executor with bounded vein mining, unload, refuel, and boot
   recovery.
3. WebSocket link, outbox, tunnel refresh, heartbeat, telemetry.
4. Console registration, station assignment, mission creation, dashboard, map,
   pause/abort/return.
5. Starter installer, runtime manifest, fixed-tag release publishing.
6. 20 Lua tests and a passing TypeScript typecheck.

Not implemented:

- GPS. The dock is the only calibration source.
- A forward depot at mining depth.
- A full per-block voxel map.
- Mission leases or TTL.
- A multi-turtle scheduler beyond one mission per turtle.
- Automatic reassignment of a lost turtle's sector.

## 17. Known limitations and open decisions

**Scale.** The 48 pilot sector is about 98k plan blocks and 409 trips at 240 new
blocks per trip, plus travel. A 90 half sector is about 335k blocks and 1,400
trips. A 128 half sector is about 668k blocks and 2,800 trips. With the dock at
Y=10, travel is a large part of every trip. Decide between a smaller sector, a
forward depot, or accepting long run times.

**Map granularity.** The server saves the deterministic tunnel cells and the
sparse ore cells. It does not save every tunnel block. Vein tunnels without ore
are not represented. This is enough for a progress map and an ore map; it is not
a voxel snapshot.

**Mission lifetime.** There is no lease or TTL. A mission stays active until it
is done, failed, or paused. A lost turtle's mission is not expired, and its
sector is not reassigned. A human decides when to intervene.

**Paused and halted state.** A local `paused` or `halted` flag blocks automatic
resume after a reboot. The dashboard start is the explicit resume. If the server
loses a paused result, the hello's state still blocks the re-offer.

**Fuel chest discipline.** The turtle pulls from the chest above the dock. If
that chest contains non-fuel items, the turtle's inventory fills and trips fail.
Use a fuel-only chest.

**Output chest capacity.** A full output chest stops unloading. The turtle
reports `no progress this trip (fuel or inventory)` and fails the mission. Empty
the chest before starting a long run.

**PRNG.** The installer uses CC's `math.random`, not a cryptographic source. The
secret is not suitable for a hostile public service.

**HTTP allowlist.** The release redirect to `objects.githubusercontent.com` must
be allowed. The OpenTunnel host must be allowed. A strict whitelist will break
the installer or the WebSocket.

**Tunnel dependency.** OpenTunnel is an external service. The console prints a
warning if it cannot resolve a URL. `PUBLIC_URL` is the manual escape hatch.

**Station spacing.** Keep `STATION_SPACING > 2 * SECTOR_HALF + margin`. The
default 256 is fine for 48. If you raise the sector half toward 128, raise the
spacing as well.

**Re-mining.** A new mission on the same station walks the same deterministic
plan. Old tunnels are air, so the turtle mostly travels; remaining ores are
still found by the neighbor inspection. There is no per-mission sector
allocation.

Open decisions:

1. Turtle count and sector size for the first real run.
2. Whether to add a forward depot at mining depth.
3. Whether a full voxel map is needed.
4. Whether to add mission leases and a scheduler for more than a few turtles.
5. The exact NeoForge ore tags for the modpack; `c:ores` and `forge:ores` are
   checked, and the `_ore` suffix is the fallback.

## 18. Quick start

Console:

```
cd console
cp .env.example .env
# edit .env: PORT, ADMIN_TOKEN, GITHUB_REPO, RELEASE_TAG, geometry
npm install
npm start
```

Before the first start:

- Install the OpenTunnel CLI and run `opentunnel route add <PORT>` once, or set
  `PUBLIC_URL`.
- Authenticate `gh` with `gh auth login` if `PUBLISH=1`.
- Confirm the repository in `GITHUB_REPO` is the one you control.

Build the dock at the station anchor:

- output chest at `(0,-1,0)`,
- turtle at `(0,0,0)` facing north,
- rear wall at `(0,0,1)`,
- west wall at `(-1,0,0)`,
- shaft air at `(0,0,-1)`,
- fuel chest at `(0,1,0)` filled with fuel.

Install on the turtle:

```
wget https://github.com/Igidn/cc-util/releases/download/tunnel-latest/install.lua install.lua
install
```

Open the dashboard. The first mission starts automatically. After it finishes,
use start for the next mission, return to pause, and abort to fail and recall.
The map link on each mission row returns the derived tunnel cells and saved ore
cells.
