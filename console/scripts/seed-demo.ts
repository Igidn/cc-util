import fs from "node:fs";
import path from "node:path";
import { config } from "../src/config.js";
import { buildDemoState, DEMO_UNITS } from "./demo-data.js";

const targetDir = process.env.DATA_DIR
  ? config.dataDir
  : path.join(config.root, "data", "demo");
const file = path.join(targetDir, "state.json");
const state = buildDemoState();

fs.mkdirSync(targetDir, { recursive: true });
fs.writeFileSync(file, JSON.stringify(state, null, 2));

const online = DEMO_UNITS.filter((unit) => unit.connect).length;
console.log(`[seed] wrote ${file}`);
console.log(
  `[seed] ${DEMO_UNITS.length} turtles · ${online} live on demo start · ${Object.keys(state.missions).length} missions · ${state.events.length} events · ${Object.values(state.maps).reduce((sum, map) => sum + Object.keys(map.ores).length, 0)} ore cells`,
);
console.log("");
console.log("run the demo server:");
console.log("  DATA_DIR=data/demo PUBLIC_URL=http://127.0.0.1:3000 PUBLISH=0 npm start");
console.log("connect the simulated turtles in another shell:");
console.log("  DATA_DIR=data/demo npm run demo:turtles");
