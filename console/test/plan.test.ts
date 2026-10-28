import assert from "node:assert/strict";
import test from "node:test";
import { buildLegs } from "../src/plan.js";
import type { MissionSpec } from "../shared/api.js";

type BranchSpec = Extract<MissionSpec, { kind: "branchMine" }>;

const DIRS: Record<number, [number, number]> = {
  0: [0, -1],
  1: [1, 0],
  2: [0, 1],
  3: [-1, 0],
};

/** Cells the miner walks at the mining level (the shaft staging step excluded). */
function minedCells(spec: BranchSpec): Set<string> {
  const legs = buildLegs(spec);
  const cells = new Set<string>();
  let x = 0;
  let z = 0;
  for (let i = 1; i < legs.length; i += 1) {
    const leg = legs[i];
    if (leg.kind !== "line") continue;
    const [dx, dz] = DIRS[leg.dir];
    for (let step = 0; step < leg.length; step += 1) {
      x += dx;
      z += dz;
      cells.add(`${x},${z}`);
    }
  }
  return cells;
}

function laneSpec(lane: number, laneCount: number, half = 4, staging = 1): BranchSpec {
  const width = Math.max(1, Math.ceil((half * 2 + 1) / laneCount));
  const x0 = -half + lane * width;
  const x1 = lane >= laneCount - 1 ? half : Math.min(half, x0 + width - 1);
  return {
    kind: "branchMine",
    base: { x: 0, y: 10, z: 0, f: 0 },
    baseVersion: 2,
    staging,
    sector: { x0, z0: -half - staging, x1, z1: half - staging },
    lane,
    laneCount,
    startY: -11,
    endY: -13,
    layerStep: 2,
    spacing: 2,
    maxRadius: half,
    maxTripBlocks: 100,
    maxVeinBlocks: 0,
    reserve: 0,
  };
}

test("split lanes cover the sector without sharing mining cells", () => {
  const half = 4;
  const lane0 = minedCells(laneSpec(0, 2, half));
  const lane1 = minedCells(laneSpec(1, 2, half));

  for (const cell of lane0) {
    assert.equal(lane1.has(cell), false, `lane 1 also mines ${cell}`);
  }

  const minX = Math.min(...[...lane0, ...lane1].map((cell) => Number(cell.split(",")[0])));
  const maxX = Math.max(...[...lane0, ...lane1].map((cell) => Number(cell.split(",")[0])));
  assert.equal(minX, -half);
  assert.equal(maxX, half);

  const columns = new Set([...lane0, ...lane1].map((cell) => Number(cell.split(",")[0])));
  for (let x = -half; x <= half; x += 1) {
    assert.equal(columns.has(x), true, `column ${x} is never mined`);
  }
});
