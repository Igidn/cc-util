import { describe, it } from "node:test";
import assert from "node:assert";
import { acquireShaft, releaseShaft, getShaftStatus, forceReleaseShaft, expireStaleLocks } from "../src/shaft.js";
import { store } from "../src/store.js";

function reset() {
  store.data.shaftLocks = {};
  store.save();
}

describe("shaft queue", () => {
  it("grants immediately when no holder and empty queue", () => {
    reset();
    const r = acquireShaft("s0", "turtle-a");
    assert.ok("granted" in r);
    assert.equal((r as { granted: boolean }).granted, true);
    const status = getShaftStatus("s0");
    assert.equal(status?.holderTurtleId, "turtle-a");
  });

  it("queues a second turtle when one holds the lock", () => {
    reset();
    acquireShaft("s0", "turtle-a");
    const r = acquireShaft("s0", "turtle-b");
    assert.ok("queued" in r);
    assert.equal((r as { queued: boolean; position: number }).queued, true);
    assert.equal((r as { position: number }).position, 1);
  });

  it("rejects when queue is full", () => {
    reset();
    acquireShaft("s0", "turtle-a");
    for (let i = 2; i <= 9; i++) {
      acquireShaft("s0", `turtle-${i}`);
    }
    const r = acquireShaft("s0", "turtle-10");
    assert.ok("rejected" in r);
  });

  it("releases and promotes next in queue", () => {
    reset();
    acquireShaft("s0", "turtle-a");
    acquireShaft("s0", "turtle-b");
    acquireShaft("s0", "turtle-c");
    const rel = releaseShaft("s0", "turtle-a");
    assert.ok("ok" in rel && (rel as { ok: boolean }).ok);
    assert.equal((rel as { next?: string }).next, "turtle-b");
    const status = getShaftStatus("s0");
    assert.equal(status?.holderTurtleId, "turtle-b");
    assert.equal(status?.queue.length, 1);
    assert.equal(status?.queue[0], "turtle-c");
  });

  it("force release promotes next waiter", () => {
    reset();
    acquireShaft("s0", "turtle-a");
    acquireShaft("s0", "turtle-b");
    const rel = forceReleaseShaft("s0");
    assert.ok("ok" in rel && (rel as { ok: boolean }).ok);
    assert.equal((rel as { next?: string }).next, "turtle-b");
    const status = getShaftStatus("s0");
    assert.equal(status?.holderTurtleId, "turtle-b");
  });

  it("non-holder cannot release", () => {
    reset();
    acquireShaft("s0", "turtle-a");
    const rel = releaseShaft("s0", "turtle-b");
    assert.ok(!("ok" in rel) || !(rel as { ok: boolean }).ok);
  });

  it("expireStaleLocks releases TTL-expired holder", () => {
    reset();
    acquireShaft("s0", "turtle-a");
    const lock = store.data.shaftLocks["s0"];
    lock.expiresAt = Date.now() - 1000;
    store.save();
    expireStaleLocks();
    const status = getShaftStatus("s0");
    assert.equal(status?.holderTurtleId, null);
  });
});
