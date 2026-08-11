import type { UpdateRouterRequest } from "@/lib/types";

function requiredText(value: unknown, label: string): string {
  if (typeof value !== "string") throw new Error(`${label} must be a string.`);
  const normalized = value.trim();
  if (!normalized) throw new Error(`${label} is required.`);
  if (normalized.length > 256) throw new Error(`${label} must be 256 characters or fewer.`);
  return normalized;
}

function optionalPeer(value: unknown): string | undefined {
  if (value === undefined || value === null || value === "") return undefined;
  return requiredText(value, "Peer ID");
}

function peerGroups(value: unknown): string[] | undefined {
  if (value === undefined || value === null) return undefined;
  if (!Array.isArray(value)) throw new Error("Peer groups must be an array.");
  return [...new Set(value.map((group) => requiredText(group, "Peer group ID")))];
}

function requiredBoolean(value: unknown, label: string): boolean {
  if (typeof value !== "boolean") throw new Error(`${label} must be true or false.`);
  return value;
}

export function parseRouterUpdateRequest(value: unknown): UpdateRouterRequest {
  if (!value || typeof value !== "object") throw new Error("Request body must be a JSON object.");
  const body = value as Record<string, unknown>;
  const peer = optionalPeer(body.peer);
  const groups = peerGroups(body.peer_groups);
  const hasPeer = Boolean(peer);
  const hasGroups = Boolean(groups?.length);

  if (hasPeer === hasGroups) {
    throw new Error("Choose exactly one router source: one peer or at least one peer group.");
  }
  if (!Number.isInteger(body.metric) || (body.metric as number) < 1 || (body.metric as number) > 9_999) {
    throw new Error("Router metric must be an integer between 1 and 9999.");
  }

  return {
    networkId: requiredText(body.networkId, "Network ID"),
    ...(peer ? { peer } : { peer_groups: groups }),
    metric: body.metric as number,
    masquerade: requiredBoolean(body.masquerade, "Masquerade"),
    enabled: requiredBoolean(body.enabled, "Enabled"),
  };
}
