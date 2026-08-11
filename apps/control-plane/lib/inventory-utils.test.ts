import { describe, expect, it } from "vitest";
import {
  buildAwsCandidates,
  buildEc2ResourceName,
  buildMongoConnections,
  classifyMongoEnvironment,
  normalizeMongoDomain,
  preflightBulkResources,
  redactMongoCredentials,
  summarizeBulkTarget,
} from "./inventory-utils";
import type { BulkResourceInput, NetBirdResource } from "./types";

describe("AWS resource naming", () => {
  it("keeps the instance ID and includes a readable EC2 Name tag", () => {
    expect(buildEc2ResourceName("i-012345", "  API   worker  ")).toBe("i-012345 (API worker)");
    expect(buildEc2ResourceName("i-067890", "")).toBe("i-067890");
  });

  it("adds environment and region only when an RDS identifier collides", () => {
    const resources = buildAwsCandidates(
      [
        {
          environment: "production",
          schema: "aws_production",
          rows: [
            {
              account_id: "111",
              region: "ap-southeast-1",
              instance_id: "i-01",
              instance_name: "gateway",
              private_dns_name: "ip-10-0-0-1.internal",
              instance_state: "running",
              instance_type: "t3.small",
              sp_connection_name: "aws_production",
            },
          ],
        },
      ],
      [
        {
          environment: "production",
          schema: "aws_production",
          rows: [
            {
              account_id: "111",
              region: "ap-southeast-1",
              db_instance_identifier: "kong",
              endpoint_address: "kong.sg.rds.amazonaws.com",
              engine: "postgres",
              status: "available",
              sp_connection_name: "aws_production",
            },
            {
              account_id: "111",
              region: "ap-east-1",
              db_instance_identifier: "kong",
              endpoint_address: "kong.hk.rds.amazonaws.com",
              engine: "postgres",
              status: "available",
              sp_connection_name: "aws_production",
            },
            {
              account_id: "111",
              region: "ap-east-1",
              db_instance_identifier: "orders",
              endpoint_address: "orders.rds.amazonaws.com",
              engine: "postgres",
              status: "available",
              sp_connection_name: "aws_production",
            },
          ],
        },
      ],
    );

    expect(resources.find((item) => item.sourceId === "i-01")?.resourceName).toBe("i-01 (gateway)");
    expect(resources.filter((item) => item.sourceId === "kong").map((item) => item.resourceName).sort()).toEqual([
      "kong (production-ap-east-1)",
      "kong (production-ap-southeast-1)",
    ]);
    expect(resources.find((item) => item.sourceId === "orders")?.resourceName).toBe("orders");
  });
});

describe("MongoDB connection extraction", () => {
  it("walks nested Atlas strings and reduces each URL to one unique domain", () => {
    const credentialedMongoUrl = [
      "mongodb://",
      "user",
      ":",
      "password",
      "@host-a.mongodb.net:27017",
    ].join("");

    const connections = buildMongoConnections([
      {
        name: "nonprod",
        project_id: "project-1",
        state_name: "IDLE",
        mongo_uri: credentialedMongoUrl,
        mongo_uri_with_options: null,
        srv_address: "mongodb+srv://nonprod.mongodb.net",
        connection_strings: {
          standardSrv: "mongodb+srv://nonprod.mongodb.net",
          privateEndpoint: [
            { connectionString: "mongodb://private.mongodb.net:27017/?ssl=true" },
          ],
        },
      },
    ]);

    expect(connections).toHaveLength(3);
    expect(connections.map((connection) => connection.domain).sort()).toEqual([
      "host-a.mongodb.net",
      "nonprod.mongodb.net",
      "private.mongodb.net",
    ]);
    expect(connections.every((connection) => connection.environment === "staging")).toBe(true);
    expect(connections.every((connection) => connection.kind === "mongodb")).toBe(true);
    const credentialedSrvUrl = [
      "mongodb+srv://",
      "admin",
      ":",
      "secret",
      "@cluster.mongodb.net",
    ].join("");

    expect(redactMongoCredentials(credentialedSrvUrl)).toBe(
      "mongodb+srv://***:***@cluster.mongodb.net",
    );
  });

  it("strips credentials, ports, paths, and extra replica hosts", () => {
    const credentialedReplicaSetUrl = [
      "mongodb://",
      "user",
      ":",
      "secret",
      "@cluster-shard-00-00.example.mongodb.net:27017,",
      "cluster-shard-00-01.example.mongodb.net:27018/database?tls=true",
    ].join("");

    expect(
      normalizeMongoDomain(credentialedReplicaSetUrl),
    ).toBe("cluster-shard-00-00.example.mongodb.net");
    expect(normalizeMongoDomain("mongodb+srv://production.example.mongodb.net./database"))
      .toBe("production.example.mongodb.net");
    expect(normalizeMongoDomain("https://example.mongodb.net:27017")).toBeUndefined();
  });

  it("classifies production and staging names without guessing unmatched clusters", () => {
    expect(classifyMongoEnvironment("uk-production-cluster")).toBe("production");
    expect(classifyMongoEnvironment("aldrev-dev-cluster")).toBe("staging");
    expect(classifyMongoEnvironment("sg-development-cluster")).toBe("staging");
    expect(classifyMongoEnvironment("nonprod-cluster")).toBe("staging");
    expect(classifyMongoEnvironment("sg-staging-xero")).toBe("staging");
    expect(classifyMongoEnvironment("sleek-training")).toBe("unclassified");
  });
});

describe("bulk preflight", () => {
  const resource = (overrides: Partial<BulkResourceInput>): BulkResourceInput => ({
    key: "production:rds:one",
    name: "orders",
    address: "orders.internal",
    kind: "rds",
    environment: "production",
    accountId: "111",
    region: "ap-southeast-1",
    ...overrides,
  });

  it("skips existing and within-batch duplicates while preserving ready rows", () => {
    const result = preflightBulkResources(
      [
        resource({ key: "1", name: "existing-name", address: "new-address.internal" }),
        resource({ key: "2", name: "new-name", address: "existing-address.internal." }),
        resource({ key: "3", name: "ready", address: "READY.INTERNAL." }),
        resource({ key: "4", name: "ready", address: "other.internal" }),
        resource({ key: "5", name: "other", address: "ready.internal" }),
      ],
      [{ name: "Existing-Name", address: "existing-address.internal" }],
    );

    expect(result.ready).toHaveLength(1);
    expect(result.ready[0]).toMatchObject({ key: "3", address: "ready.internal" });
    expect(result.results.map((item) => item.status)).toEqual([
      "duplicate",
      "duplicate",
      "ready",
      "duplicate",
      "duplicate",
    ]);
  });

  it("reports the matching NetBird location for existing resources", () => {
    const result = preflightBulkResources(
      [resource({ key: "1", name: "orders", address: "orders.internal" })],
      [{
        name: "orders",
        address: "orders.internal",
        networkName: "Production data plane",
        groups: [{ id: "group-platform", name: "Platform" }],
      }],
    );

    expect(result.results[0].reason).toBe("A NetBird resource already uses this name in network Production data plane (groups: Platform).");
  });

  it("counts target network resources and unique resources across selected groups", () => {
    const existing: NetBirdResource[] = [
      {
        id: "resource-1",
        name: "orders",
        address: "orders.internal",
        enabled: true,
        networkId: "network-production",
        networkName: "Production",
        groups: [{ id: "group-platform", name: "Platform" }, { id: "group-engineering", name: "Engineering" }],
      },
      {
        id: "resource-2",
        name: "billing",
        address: "billing.internal",
        enabled: true,
        networkId: "network-production",
        networkName: "Production",
        groups: [{ id: "group-platform", name: "Platform" }],
      },
      {
        id: "resource-3",
        name: "staging-orders",
        address: "staging-orders.internal",
        enabled: true,
        networkId: "network-staging",
        networkName: "Staging",
        groups: [{ id: "group-engineering", name: "Engineering" }],
      },
    ];

    expect(summarizeBulkTarget(existing, "network-production", ["group-platform", "group-engineering"])).toEqual({
      networkResourceCount: 2,
      selectedGroupResourceCount: 3,
    });
  });
});
