import http, { type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { config } from "./config.js";
import { hub } from "./hub.js";
import { mapForMission } from "./map.js";
import { register } from "./registry.js";
import { store } from "./store.js";

function json(res: ServerResponse, status: number, body: unknown): void {
  const data = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(data),
    "cache-control": "no-store",
  });
  res.end(data);
}

async function readBody(req: IncomingMessage): Promise<unknown> {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks: Buffer[] = [];
    req.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > 1_000_000) {
        reject(new Error("body too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      try {
        resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString("utf8")) : {});
      } catch {
        reject(new Error("invalid json"));
      }
    });
    req.on("error", reject);
  });
}

function authorized(req: IncomingMessage, url: URL): boolean {
  if (!config.adminToken) return true;
  const header = req.headers.authorization ?? "";
  const bearer = header.startsWith("Bearer ") ? header.slice(7) : "";
  return bearer === config.adminToken || url.searchParams.get("token") === config.adminToken;
}

function esc(value: unknown): string {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function dashboard(): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>cc-util console</title>
<style>
  :root { color-scheme: dark; --bg:#0b0e14; --panel:#121722; --line:#243044; --text:#dbe4f0; --dim:#7d8ba1; --accent:#6ee7b7; --warn:#fbbf24; --bad:#fb7185; }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--text); font:14px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace; }
  header { padding:18px 22px; border-bottom:1px solid var(--line); display:flex; gap:18px; align-items:baseline; flex-wrap:wrap; }
  h1 { font-size:16px; margin:0; letter-spacing:.04em; }
  .url { color:var(--dim); word-break:break-all; }
  main { padding:18px 22px; }
  table { width:100%; border-collapse:collapse; }
  th,td { text-align:left; padding:8px 10px; border-bottom:1px solid var(--line); vertical-align:top; }
  th { color:var(--dim); font-weight:500; font-size:12px; text-transform:uppercase; letter-spacing:.06em; }
  .state { color:var(--accent); }
  .stale { color:var(--warn); }
  .fault { color:var(--bad); }
  button { background:transparent; color:var(--text); border:1px solid var(--line); border-radius:6px; padding:4px 8px; cursor:pointer; font:inherit; }
  button:hover { border-color:var(--accent); color:var(--accent); }
  .muted { color:var(--dim); }
  .bar { height:4px; background:var(--line); border-radius:2px; overflow:hidden; margin-top:5px; }
  .bar > i { display:block; height:100%; background:var(--accent); }
  pre { white-space:pre-wrap; color:var(--dim); }
</style>
</head>
<body>
<header>
  <h1>cc-util mining console</h1>
  <span class="url" id="tunnel">connecting...</span>
  <span class="muted" id="stamp"></span>
</header>
<main>
  <table>
    <thead><tr><th>turtle</th><th>station</th><th>state</th><th>pose</th><th>fuel</th><th>mission</th><th></th></tr></thead>
    <tbody id="rows"><tr><td colspan="7" class="muted">loading...</td></tr></tbody>
  </table>
  <h2 style="font-size:13px;color:var(--dim);margin-top:28px">events</h2>
  <pre id="events"></pre>
</main>
<script>
const params = new URLSearchParams(location.search);
const token = params.get("token") || "";
const q = token ? "?token=" + encodeURIComponent(token) : "";
const api = (path, method="GET") => fetch(path + q, { method, headers: token ? { authorization: "Bearer " + token } : {} });
const esc = v => String(v ?? "").replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;","\\"":"&quot;"}[c]));
function pct(m) {
  if (!m) return 0;
  if (typeof m.percent === "number") return Math.max(0, Math.min(100, m.percent));
  const p = m.progress || {};
  return Math.min(100, Math.round(((p.leg || 1) - 1) * 2 + (p.offset || 0) / 100));
}
async function tick() {
  try {
    const r = await api("/api/state");
    const s = await r.json();
    document.getElementById("tunnel").textContent = s.tunnelUrl || "no tunnel";
    document.getElementById("stamp").textContent = new Date().toLocaleTimeString();
    const online = new Set(s.online || []);
    document.getElementById("rows").innerHTML = (s.turtles || []).map(t => {
      const m = (s.missions || []).find(x => x.id === t.missionId || (x.turtleId === t.id && x.state !== "done" && x.state !== "failed"));
      const cls = t.state === "stale" ? "stale" : (t.state === "fault" ? "fault" : "state");
      const pose = t.pose ? t.pose.x + "," + t.pose.y + "," + t.pose.z + " f" + t.pose.f : "-";
      return "<tr><td>" + esc(t.label || t.id) + "<br><span class=\\"muted\\">" + esc(t.id) + "</span></td>" +
        "<td>" + esc(t.stationId) + "</td>" +
        "<td class=\\"" + cls + "\\">" + esc(t.state) + (online.has(t.id) ? "" : " (offline)") + "</td>" +
        "<td>" + esc(pose) + "</td>" +
        "<td>" + esc(t.fuel) + "</td>" +
        "<td>" + (m ? esc(m.state) + "<div class=\\"bar\\"><i style=\\"width:" + pct(m) + "%\\"></i></div>" +
          " <a class=\\"muted\\" target=\\"_blank\\" href=\\"/api/map?missionId=" + encodeURIComponent(m.id) + (token ? "&token=" + encodeURIComponent(token) : "") + "\\">map</a>" : "-") + "</td>" +
        "<td><button data-id=\\"" + esc(t.id) + "\\" data-op=\\"start\\">start</button> " +
        "<button data-id=\\"" + esc(t.id) + "\\" data-op=\\"return\\">return</button> " +
        "<button data-id=\\"" + esc(t.id) + "\\" data-op=\\"abort\\">abort</button></td></tr>";
    }).join("") || "<tr><td colspan=\\"7\\" class=\\"muted\\">no turtles registered</td></tr>";
    document.querySelectorAll("button[data-op]").forEach(b => b.onclick = async () => {
      await api("/api/turtles/" + encodeURIComponent(b.dataset.id) + "/" + b.dataset.op, "POST");
      tick();
    });
    document.getElementById("events").textContent = (s.events || []).slice(0, 12).map(e =>
      new Date(e.at).toLocaleTimeString() + "  " + e.turtleId + "  " + e.kind + "  " + JSON.stringify(e.data)
    ).join("\\n");
  } catch (e) {
    document.getElementById("stamp").textContent = "offline";
  }
}
tick();
setInterval(tick, 2000);
</script>
</body>
</html>`;
}

export function createServer(): Server {
  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url ?? "/", "http://localhost");
    try {
      if (req.method === "GET" && url.pathname === "/") {
        const html = dashboard();
        res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
        res.end(html);
        return;
      }

      if (req.method === "GET" && url.pathname === "/api/health") {
        json(res, 200, { ok: true, uptime: process.uptime() });
        return;
      }

      if (req.method === "GET" && url.pathname === "/api/tunnel") {
        json(res, 200, { url: hub.tunnelUrl });
        return;
      }

      if (req.method === "POST" && url.pathname === "/api/register") {
        const body = await readBody(req);
        const result = register(body);
        if (!result.ok) {
          json(res, 400, { ok: false, error: result.error });
          return;
        }
        json(res, 200, {
          ok: true,
          id: result.turtle.id,
          station: result.station,
          server: hub.tunnelUrl,
          protocol: 1,
        });
        return;
      }

      if (req.method === "GET" && url.pathname === "/api/state") {
        if (!authorized(req, url)) {
          json(res, 401, { ok: false, error: "unauthorized" });
          return;
        }
        json(res, 200, hub.snapshot());
        return;
      }

      if (req.method === "GET" && url.pathname === "/api/map") {
        if (!authorized(req, url)) {
          json(res, 401, { ok: false, error: "unauthorized" });
          return;
        }
        const missionId = url.searchParams.get("missionId") ?? "";
        const mission = missionId ? store.data.missions[missionId] : undefined;
        if (!mission) {
          json(res, 404, { ok: false, error: "unknown mission" });
          return;
        }
        json(res, 200, mapForMission(mission));
        return;
      }

      const control = url.pathname.match(/^\/api\/turtles\/([^/]+)\/(start|abort|return)$/);
      if (req.method === "POST" && control) {
        if (!authorized(req, url)) {
          json(res, 401, { ok: false, error: "unauthorized" });
          return;
        }
        const id = decodeURIComponent(control[1]);
        const op = control[2];
        const ok = op === "start" ? hub.start(id) : op === "abort" ? hub.abort(id) : hub.returnHome(id);
        json(res, ok ? 200 : 409, { ok });
        return;
      }

      json(res, 404, { ok: false, error: "not found" });
    } catch (error) {
      json(res, 500, { ok: false, error: (error as Error).message });
    }
  });

  return server;
}
