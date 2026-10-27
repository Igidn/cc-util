import { store } from "./store.js";
import type { Chest } from "./types.js";

/** Register a newly placed chest. Called by the station builder turtle. */
export function placeChest(chest: Chest): Chest {
  store.data.chests[chest.id] = chest;

  // Update the station's storage chest fill tracking if this is a storage chest.
  const station = store.data.stations[chest.stationId];
  if (station && chest.kind === "storage") {
    // Count how many storage chests exist for this station.
    const storageChests = Object.values(store.data.chests).filter(
      (c) => c.stationId === chest.stationId && c.kind === "storage",
    );
    station.storageChestCount = storageChests.length;
    store.save();
  }

  store.event("system", "chest_placed", { stationId: chest.stationId, chestId: chest.id, kind: chest.kind, pose: chest.pose });
  return chest;
}

/** List all chests, optionally filtered by station. */
export function listChests(stationId?: string): Chest[] {
  const chests = Object.values(store.data.chests);
  if (stationId) {
    return chests.filter((c) => c.stationId === stationId);
  }
  return chests;
}

/** Update a chest's fill percentage and last-filled timestamp. */
export function updateChestFill(chestId: string, fillPercent: number): Chest | null {
  const chest = store.data.chests[chestId];
  if (!chest) return null;
  chest.fillPercent = Math.max(0, Math.min(100, fillPercent));
  chest.filledAt = Date.now();
  store.save();

  // Recompute station storage fill count.
  const station = store.data.stations[chest.stationId];
  if (station) {
    const storageChests = Object.values(store.data.chests).filter(
      (c) => c.stationId === chest.stationId && c.kind === "storage",
    );
    const filled = storageChests.filter((c) => (c.fillPercent ?? 0) > 0).length;
    station.storageChestCount = storageChests.length;
    station.storageChestsFilled = filled;
    store.save();
  }

  return chest;
}

/** Get all storage chests for a station, sorted by fill percent ascending (least full first). */
export function getStorageChests(stationId: string): Chest[] {
  return Object.values(store.data.chests).filter(
    (c) => c.stationId === stationId && c.kind === "storage",
  ).sort((a, b) => (a.fillPercent ?? 0) - (b.fillPercent ?? 0));
}

/** Get the refueling chest for a station. */
export function getRefuelChest(stationId: string): Chest | null {
  return (
    Object.values(store.data.chests).find(
      (c) => c.stationId === stationId && c.kind === "refuel",
    ) ?? null
  );
}
