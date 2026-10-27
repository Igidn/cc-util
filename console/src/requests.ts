import { randomUUID } from "node:crypto";
import { store } from "./store.js";
import type { ItemRequest } from "./types.js";

/** Create a new item request (player wants ores/blocks brought up). */
export function createRequest(stationId: string, requestedBy: string, itemName: string, count: number): ItemRequest {
  const request: ItemRequest = {
    id: randomUUID(),
    stationId,
    requestedBy,
    itemName,
    count,
    status: "pending",
    createdAt: Date.now(),
    updatedAt: Date.now(),
  };
  store.data.requests[request.id] = request;
  store.save();
  store.event("system", "item_request_created", { requestId: request.id, stationId, itemName, count, requestedBy });
  return request;
}

/** List all requests, optionally filtered by station and/or status. */
export function listRequests(stationId?: string, status?: ItemRequest["status"]): ItemRequest[] {
  let requests = Object.values(store.data.requests);
  if (stationId) {
    requests = requests.filter((r) => r.stationId === stationId);
  }
  if (status) {
    requests = requests.filter((r) => r.status === status);
  }
  return requests.sort((a, b) => b.createdAt - a.createdAt);
}

/** Get a single request by id. */
export function getRequest(id: string): ItemRequest | null {
  return store.data.requests[id] ?? null;
}

/** Cancel a request. */
export function cancelRequest(id: string): ItemRequest | null {
  const request = store.data.requests[id];
  if (!request) return null;
  if (request.status !== "pending" && request.status !== "assigned") return request;
  request.status = "cancelled";
  request.updatedAt = Date.now();
  store.save();
  store.event("system", "item_request_cancelled", { requestId: id, stationId: request.stationId });
  return request;
}

/** Assign a request to a hauler turtle. */
export function assignRequest(id: string, haulerId: string): ItemRequest | null {
  const request = store.data.requests[id];
  if (!request) return null;
  if (request.status !== "pending") return null;
  request.status = "assigned";
  request.haulerId = haulerId;
  request.updatedAt = Date.now();
  store.save();
  store.event("system", "item_request_assigned", { requestId: id, haulerId, stationId: request.stationId });
  return request;
}

/** Mark a request as delivered. */
export function deliverRequest(id: string): ItemRequest | null {
  const request = store.data.requests[id];
  if (!request) return null;
  request.status = "delivered";
  request.updatedAt = Date.now();
  store.save();
  store.event("system", "item_request_delivered", { requestId: id, stationId: request.stationId });
  return request;
}
