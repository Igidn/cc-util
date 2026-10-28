import { config } from "./config.js";
import { store } from "./store.js";
import type { ShaftLock } from "./types.js";

const SHAFT_TTL_MS = 5 * 60 * 1000; // 5 minutes auto-release
const MAX_QUEUE = 8;

/** Acquire shaft access for a turtle. Returns { granted: true } or { queued: number, position: number }. */
export function acquireShaft(stationId: string, turtleId: string): { granted: true } | { queued: true; position: number } | { rejected: true; reason: string } {
  let lock = store.data.shaftLocks[stationId];
  if (!lock) {
    lock = {
      stationId,
      holderTurtleId: null,
      queue: [],
      acquiredAt: null,
      expiresAt: null,
    };
    store.data.shaftLocks[stationId] = lock;
  }

  // Already holding the lock. This is also the keepalive path for a long
  // traversal: renew the TTL so a 769-block round trip never expires it.
  if (lock.holderTurtleId === turtleId) {
    lock.expiresAt = Date.now() + SHAFT_TTL_MS;
    store.save();
    return { granted: true };
  }

  // Already in queue.
  if (lock.queue.includes(turtleId)) {
    const position = lock.queue.indexOf(turtleId) + 1;
    return { queued: true, position };
  }

  // No holder and empty queue -> grant immediately.
  if (!lock.holderTurtleId && lock.queue.length === 0) {
    lock.holderTurtleId = turtleId;
    lock.acquiredAt = Date.now();
    lock.expiresAt = Date.now() + SHAFT_TTL_MS;
    store.save();
    return { granted: true };
  }

  // Queue is full.
  if (lock.queue.length >= MAX_QUEUE) {
    return { rejected: true, reason: "shaft queue full" };
  }

  // Enqueue.
  lock.queue.push(turtleId);
  store.save();
  return { queued: true, position: lock.queue.length };
}

/** Release shaft access. Promotes the next waiter if any. */
export function releaseShaft(stationId: string, turtleId: string): { ok: true; next?: string } | { ok: false; reason: string } {
  const current = store.data.shaftLocks[stationId];
  if (!current) {
    // No lock ever existed for this station; nothing to release. Idempotent.
    return { ok: true };
  }
  if (current.holderTurtleId === null) {
    // Lock already released (e.g. TTL expired and force-cleared). Idempotent.
    return { ok: true };
  }
  if (current.holderTurtleId !== turtleId) {
    return { ok: false, reason: "turtle is not the shaft holder" };
  }

  current.holderTurtleId = null;
  current.acquiredAt = null;
  current.expiresAt = null;

  const next = current.queue.shift();
  if (next) {
    current.holderTurtleId = next;
    current.acquiredAt = Date.now();
    current.expiresAt = Date.now() + SHAFT_TTL_MS;
    store.save();
    return { ok: true, next };
  }

  store.save();
  return { ok: true };
}

/** Get the current shaft status for a station. */
export function getShaftStatus(stationId: string): ShaftLock | null {
  return store.data.shaftLocks[stationId] ?? null;
}

/** Force-release a stale lock (called by the stale-checker or admin). */
export function forceReleaseShaft(stationId: string): { ok: true; next?: string } | { ok: false; reason: string } {
  const lock = store.data.shaftLocks[stationId];
  if (!lock || !lock.holderTurtleId) {
    return { ok: false, reason: "no active holder" };
  }
  const holder = lock.holderTurtleId;
  lock.holderTurtleId = null;
  lock.acquiredAt = null;
  lock.expiresAt = null;

  const next = lock.queue.shift();
  if (next) {
    lock.holderTurtleId = next;
    lock.acquiredAt = Date.now();
    lock.expiresAt = Date.now() + SHAFT_TTL_MS;
    store.save();
    return { ok: true, next };
  }

  store.save();
  return { ok: true };
}

/** Check all locks and force-release any whose TTL has expired. */
export function expireStaleLocks(): void {
  const now = Date.now();
  for (const [stationId, lock] of Object.entries(store.data.shaftLocks)) {
    if (lock.holderTurtleId && lock.expiresAt && now > lock.expiresAt) {
      forceReleaseShaft(stationId);
      store.event(lock.holderTurtleId, "shaft_ttl_expired", { stationId });
    }
  }
}
