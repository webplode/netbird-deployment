import { describe, expect, it } from "vitest";
import { parsePolicyRequest, parsePortInput } from "./policy-validation";

const baseRule = (overrides: Record<string, unknown> = {}) => ({
  name: "App to database",
  description: "",
  enabled: true,
  action: "accept",
  bidirectional: false,
  protocol: "tcp",
  sources: ["group-source"],
  destinations: ["group-destination"],
  ...overrides,
});

describe("NetBird policy validation", () => {
  it("accepts group and resource endpoints with TCP ports and ranges", () => {
    const policy = parsePolicyRequest({
      name: "Database access",
      description: "",
      enabled: false,
      source_posture_checks: ["posture-check"],
      rules: [
        baseRule({ id: "rule-existing", ports: ["443", "3306"], port_ranges: [{ start: 10_000, end: 10_100 }], authorized_groups: { "group-source": ["database-user"] } }),
        baseRule({
          name: "Resource endpoint",
          sources: undefined,
          sourceResource: { id: "resource-source", type: "domain" },
          destinations: undefined,
          destinationResource: { id: "resource-destination", type: "peer" },
        }),
      ],
    });

    expect(policy.rules).toHaveLength(2);
    expect(policy.source_posture_checks).toEqual(["posture-check"]);
    expect(policy.rules[0]).toMatchObject({ id: "rule-existing", ports: ["443", "3306"], port_ranges: [{ start: 10_000, end: 10_100 }], authorized_groups: { "group-source": ["database-user"] } });
    expect(policy.rules[1]).toMatchObject({ sourceResource: { id: "resource-source", type: "domain" } });
  });

  it("rejects ambiguous endpoints and invalid non-TCP/UDP ports", () => {
    expect(() => parsePolicyRequest({ name: "x", description: "", enabled: true, rules: [baseRule({ sourceResource: { id: "r", type: "domain" } })] }))
      .toThrow("source must use groups or one resource");
    expect(() => parsePolicyRequest({ name: "x", description: "", enabled: true, rules: [baseRule({ protocol: "icmp", ports: ["80"] })] }))
      .toThrow("ports are only supported for TCP or UDP");
  });

  it("parses ports and ranges from the compact editor format", () => {
    expect(parsePortInput("80, 443, 1000-2000, 80")).toEqual({
      ports: ["80", "443"],
      port_ranges: [{ start: 1000, end: 2000 }],
    });
    expect(() => parsePortInput("80,not-a-port")).toThrow("Ports must use comma-separated");
  });
});
