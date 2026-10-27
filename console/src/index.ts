import { config } from "./config.js";
import { createServer } from "./http.js";
import { hub } from "./hub.js";
import { publishRelease, releaseBase, writeRuntime } from "./publish.js";
import { attachRealtime, closeRealtime } from "./realtime.js";
import { store } from "./store.js";
import { ensureTunnel } from "./tunnel.js";

async function main(): Promise<void> {
  const server = createServer();
  hub.attach(server);
  attachRealtime(server);

  await new Promise<void>((resolve) => {
    server.listen(config.port, config.host, resolve);
  });
  console.log(`[console] listening on http://${config.host}:${config.port}`);
  if (!config.adminToken) {
    console.warn("[console] ADMIN_TOKEN is empty: control endpoints are open to anyone with the tunnel URL");
  }

  const tunnel = await ensureTunnel(config.port);
  if (!tunnel) {
    console.warn("[console] no public tunnel; turtles cannot connect from the MC server");
  } else {
    hub.tunnelUrl = tunnel;
    console.log(`[console] tunnel ${tunnel}`);

    const runtime = writeRuntime(tunnel);
    if (config.publish) {
      const ok = await publishRelease(runtime);
      console.log(`[publish] ${ok ? "published" : "FAILED"} ${releaseBase()}`);
    } else {
      console.log(`[publish] disabled (PUBLISH=0); runtime written to ${config.runtimeDir}`);
    }
  }

  console.log(
    [
      "",
      "install on a turtle:",
      `  wget ${releaseBase()}/install.lua install.lua`,
      "  install",
      "",
      `console:  http://${config.host}:${config.port}${config.adminToken ? "/?token=<ADMIN_TOKEN>" : ""}`,
      `realtime: socket.io on the same origin`,
      `rebuild:  npm run build (serves console/web/dist)`,
      "",
    ].join("\n"),
  );

  const shutdown = () => {
    store.flush();
    void closeRealtime().finally(() => {
      server.close(() => process.exit(0));
      setTimeout(() => process.exit(0), 1500).unref();
    });
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
