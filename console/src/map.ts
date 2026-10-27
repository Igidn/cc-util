import { buildLegs } from "./plan.js";
import { store } from "./store.js";
import type { Mission, MissionSpec, OreCell, Progress, Vec3 } from "./types.js";
import { isBranchMineSpec, isMiningProgress } from "../shared/api.js";

const DX = [0, 1, 0, -1] as const;
const DZ = [-1, 0, 1, 0] as const;

/**
 * Derive the tunnel cells the turtle has actually walked from the
 * deterministic plan and the persisted progress. This is not the full set of
 * mined cells: vein detours are only persisted as the ore cells they produced.
 * The plan itself is regenerated from the mission spec, so the server does not
 * need to store every tunnel cell.
 */
export function planCells(spec: MissionSpec, progress: Progress): Vec3[] {
  if (!isBranchMineSpec(spec) || !isMiningProgress(progress)) {
    return [];
  }
  const legs = buildLegs(spec);
  const cells: Vec3[] = [];
  let x = spec.base.x;
  let y = spec.base.y;
  let z = spec.base.z;

  const current = Math.min(Math.max(0, progress.leg), legs.length);
  for (let i = 1; i <= current; i++) {
    const leg = legs[i - 1];
    const length =
      i < progress.leg ? leg.length : Math.min(leg.length, Math.max(0, progress.offset));

    if (leg.kind === "down") {
      for (let n = 0; n < length; n++) {
        y -= 1;
        cells.push({ x, y, z });
      }
    } else {
      const dx = DX[leg.dir];
      const dz = DZ[leg.dir];
      for (let n = 0; n < length; n++) {
        x += dx;
        z += dz;
        cells.push({ x, y, z });
      }
    }
  }

  return cells;
}

export type MissionMap = {
  missionId: string;
  stationId: string;
  turtleId: string;
  state: string;
  progress: Progress;
  spec: MissionSpec;
  counts: { tunnel: number; ore: number };
  cells: Vec3[];
  ores: OreCell[];
};

export function mapForMission(mission: Mission): MissionMap {
  const cells = planCells(mission.spec, mission.progress);
  const turtle = store.data.turtles[mission.turtleId];
  const stationId = turtle?.stationId ?? "";
  const ores = Object.values(store.data.maps[stationId]?.ores ?? {});

  return {
    missionId: mission.id,
    stationId,
    turtleId: mission.turtleId,
    state: mission.state,
    progress: mission.progress,
    spec: mission.spec,
    counts: { tunnel: cells.length, ore: ores.length },
    cells,
    ores,
  };
}
