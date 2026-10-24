import fs from "node:fs";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { config } from "./config.js";

const exec = promisify(execFile);

type ManifestFile = { asset: string; path: string };

function walk(dir: string, base = ""): string[] {
  const out: string[] = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith(".")) continue;
    const rel = base ? `${base}/${entry.name}` : entry.name;
    if (entry.isDirectory()) {
      if (rel === "test") continue;
      out.push(...walk(path.join(dir, entry.name), rel));
    } else if (entry.name.endsWith(".lua")) {
      out.push(rel);
    }
  }
  return out;
}

export function buildManifest(): { version: string; generatedAt: number; files: ManifestFile[] } {
  const mineDir = path.resolve(config.root, "..", "mine");
  const files = walk(mineDir)
    .filter((rel) => rel !== "install.lua")
    .sort()
    .map((rel) => ({
      path: rel,
      asset: rel.replace(/\//g, "__"),
    }));
  return { version: new Date().toISOString(), generatedAt: Date.now(), files };
}

export function writeRuntime(tunnelUrl: string): {
  tunnelFile: string;
  manifestFile: string;
  assetsDir: string;
  manifest: ReturnType<typeof buildManifest>;
} {
  const runtime = config.runtimeDir;
  const assetsDir = path.join(runtime, "assets");
  fs.mkdirSync(assetsDir, { recursive: true });

  const wsUrl = tunnelUrl.replace(/^https:\/\//, "wss://").replace(/^http:\/\//, "ws://");
  const tunnelFile = path.join(runtime, "tunnel.json");
  fs.writeFileSync(
    tunnelFile,
    JSON.stringify(
      {
        url: tunnelUrl,
        wsUrl: `${wsUrl.replace(/\/+$/, "")}/ws`,
        updatedAt: Date.now(),
        tag: config.releaseTag,
      },
      null,
      2,
    ),
  );

  const manifest = buildManifest();
  const manifestFile = path.join(runtime, "manifest.json");
  fs.writeFileSync(manifestFile, JSON.stringify(manifest, null, 2));

  const mineDir = path.resolve(config.root, "..", "mine");
  for (const file of manifest.files) {
    fs.copyFileSync(path.join(mineDir, file.path), path.join(assetsDir, file.asset));
  }

  const installer = path.join(mineDir, "install.lua");
  if (fs.existsSync(installer)) {
    fs.copyFileSync(installer, path.join(runtime, "install.lua"));
  }

  return { tunnelFile, manifestFile, assetsDir, manifest };
}

async function gh(args: string[]): Promise<{ ok: boolean; output: string }> {
  try {
    const { stdout, stderr } = await exec("gh", args, { timeout: 120000 });
    return { ok: true, output: `${stdout}${stderr}` };
  } catch (error) {
    const err = error as { stdout?: string; stderr?: string; message?: string };
    return { ok: false, output: `${err.stdout ?? ""}${err.stderr ?? ""}${err.message ?? ""}` };
  }
}

/**
 * Publishes to a fixed release tag, not "latest". A later code release must
 * not break the turtle's resolver URL:
 *   https://github.com/<repo>/releases/download/<tag>/tunnel.json
 */
export async function publishRelease(runtime: ReturnType<typeof writeRuntime>): Promise<boolean> {
  const repo = config.githubRepo;
  const tag = config.releaseTag;

  const view = await gh(["release", "view", tag, "--repo", repo]);
  if (!view.ok) {
    const created = await gh([
      "release",
      "create",
      tag,
      "--repo",
      repo,
      "--title",
      "cc-util tunnel",
      "--notes",
      "Live tunnel address and Lua runtime for the CC: Tweaked mining fleet.",
      "--latest",
    ]);
    if (!created.ok) {
      console.warn("[publish] could not create release:", created.output.trim());
      return false;
    }
  }

  const files = [
    runtime.tunnelFile,
    runtime.manifestFile,
    path.join(config.runtimeDir, "install.lua"),
    ...runtime.manifest.files.map((file) => path.join(runtime.assetsDir, file.asset)),
  ].filter((file) => fs.existsSync(file));

  const upload = await gh(["release", "upload", tag, ...files, "--repo", repo, "--clobber"]);
  if (!upload.ok) {
    console.warn("[publish] upload failed:", upload.output.trim());
    return false;
  }
  return true;
}

export function releaseBase(): string {
  return `https://github.com/${config.githubRepo}/releases/download/${config.releaseTag}`;
}
