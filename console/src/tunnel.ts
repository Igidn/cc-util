import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { config } from "./config.js";

const exec = promisify(execFile);

function extractUrl(text: string): string | null {
  const match = text.match(/https:\/\/[^\s"'<>]+/);
  if (!match) return null;
  return match[0].replace(/[.,;)]+$/, "").replace(/\/+$/, "");
}

async function run(args: string[]): Promise<string> {
  const { stdout, stderr } = await exec("opentunnel", args, { timeout: 45000 });
  return `${stdout}\n${stderr}`;
}

/**
 * OpenTunnel keeps a stable tunnel hostname per profile. `route add` also
 * starts the background service. We only need the public https URL; the
 * WebSocket uses the same host with wss:// and /ws.
 */
export async function ensureTunnel(port: number): Promise<string | null> {
  if (config.publicUrl) return config.publicUrl;

  try {
    const added = await run(["route", "add", String(port)]);
    const url = extractUrl(added);
    if (url) return url;
  } catch (error) {
    console.warn("[tunnel] opentunnel route add failed:", (error as Error).message);
  }

  try {
    const status = await run(["status"]);
    const url = extractUrl(status);
    if (url) return url;
  } catch (error) {
    console.warn("[tunnel] opentunnel status failed:", (error as Error).message);
  }

  console.warn(
    "[tunnel] no public URL. Install opentunnel (npm i -g opentunnel), run " +
      "`opentunnel route add " +
      port +
      "`, or set PUBLIC_URL in .env.",
  );
  return null;
}
