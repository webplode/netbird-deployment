import { describe, expect, it } from "vitest";
import { parseRouterUpdateRequest } from "./router-validation";

describe("router update validation", () => {
  it("accepts a complete single-peer router update", () => {
    expect(parseRouterUpdateRequest({
      networkId: "network-1",
      peer: "peer-1",
      metric: 100,
      masquerade: true,
      enabled: false,
    })).toEqual({
      networkId: "network-1",
      peer: "peer-1",
      metric: 100,
      masquerade: true,
      enabled: false,
    });
  });

  it("accepts and deduplicates a peer-group router update", () => {
    expect(parseRouterUpdateRequest({
      networkId: "network-1",
      peer_groups: ["group-1", "group-2", "group-1"],
      metric: 9999,
      masquerade: false,
      enabled: true,
    })).toEqual({
      networkId: "network-1",
      peer_groups: ["group-1", "group-2"],
      metric: 9999,
      masquerade: false,
      enabled: true,
    });
  });

  it("rejects missing, conflicting, and invalid router fields", () => {
    const valid = { networkId: "network-1", metric: 100, masquerade: true, enabled: true };
    expect(() => parseRouterUpdateRequest(valid)).toThrow("Choose exactly one router source");
    expect(() => parseRouterUpdateRequest({ ...valid, peer: "peer-1", peer_groups: ["group-1"] })).toThrow("Choose exactly one router source");
    expect(() => parseRouterUpdateRequest({ ...valid, peer: "peer-1", metric: 0 })).toThrow("Router metric");
  });
});
