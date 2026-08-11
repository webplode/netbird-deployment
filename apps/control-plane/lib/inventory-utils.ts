import type {
  AwsEnvironment,
  BulkResourceInput,
  BulkResult,
  BulkTargetSummary,
  MongoConnection,
  NetBirdResource,
  ResourceCandidate,
  ResourceEnvironment,
} from "@/lib/types";

export interface Ec2Row {
  account_id: string | null;
  region: string | null;
  instance_id: string;
  instance_name: string | null;
  private_dns_name: string;
  instance_state: string | null;
  instance_type: string | null;
  sp_connection_name: string | null;
}

export interface RdsRow {
  account_id: string | null;
  region: string | null;
  db_instance_identifier: string;
  endpoint_address: string;
  engine: string | null;
  status: string | null;
  sp_connection_name: string | null;
}

export interface MongoRow {
  name: string;
  project_id: string | null;
  state_name: string | null;
  mongo_uri: string | null;
  mongo_uri_with_options: string | null;
  srv_address: string | null;
  connection_strings: unknown;
}

export function cleanLabel(value: string | null | undefined): string {
  return (value ?? "").replace(/\s+/g, " ").trim();
}

export function buildEc2ResourceName(instanceId: string, instanceName?: string | null): string {
  const name = cleanLabel(instanceName);
  return name ? `${instanceId} (${name})` : instanceId;
}

export function buildAwsCandidates(
  ec2ByEnvironment: Array<{ environment: AwsEnvironment; rows: Ec2Row[]; schema: string }>,
  rdsByEnvironment: Array<{ environment: AwsEnvironment; rows: RdsRow[]; schema: string }>,
): ResourceCandidate[] {
  const identifierCounts = new Map<string, number>();

  for (const source of rdsByEnvironment) {
    for (const row of source.rows) {
      const key = row.db_instance_identifier.toLocaleLowerCase();
      identifierCounts.set(key, (identifierCounts.get(key) ?? 0) + 1);
    }
  }

  const ec2 = ec2ByEnvironment.flatMap(({ environment, rows, schema }) =>
    rows.map((row) => {
      const instanceName = cleanLabel(row.instance_name);
      return {
        key: `${environment}:ec2:${row.instance_id}`,
        kind: "ec2" as const,
        environment,
        accountId: row.account_id ?? "unknown",
        region: row.region ?? "unknown",
        sourceConnection: row.sp_connection_name ?? schema,
        sourceId: row.instance_id,
        displayName: instanceName || row.instance_id,
        resourceName: buildEc2ResourceName(row.instance_id, instanceName),
        address: row.private_dns_name,
        status: row.instance_state ?? "unknown",
        detail: row.instance_type ?? "EC2 instance",
      };
    }),
  );

  const rds = rdsByEnvironment.flatMap(({ environment, rows, schema }) =>
    rows.map((row) => {
      const duplicate = (identifierCounts.get(row.db_instance_identifier.toLocaleLowerCase()) ?? 0) > 1;
      const region = row.region ?? "unknown";
      const resourceName = duplicate
        ? `${row.db_instance_identifier} (${environment}-${region})`
        : row.db_instance_identifier;

      return {
        key: `${environment}:rds:${region}:${row.db_instance_identifier}`,
        kind: "rds" as const,
        environment,
        accountId: row.account_id ?? "unknown",
        region,
        sourceConnection: row.sp_connection_name ?? schema,
        sourceId: row.db_instance_identifier,
        displayName: row.db_instance_identifier,
        resourceName,
        address: row.endpoint_address,
        status: row.status ?? "unknown",
        detail: row.engine ?? "RDS database",
      };
    }),
  );

  return [...ec2, ...rds].sort((left, right) => {
    const environmentOrder = left.environment === right.environment ? 0 : left.environment === "production" ? -1 : 1;
    return (
      environmentOrder ||
      left.region.localeCompare(right.region) ||
      left.kind.localeCompare(right.kind) ||
      left.displayName.localeCompare(right.displayName)
    );
  });
}

export function redactMongoCredentials(uri: string): string {
  return uri.replace(/^(mongodb(?:\+srv)?:\/\/)([^/@]+)@/i, "$1***:***@");
}

export function classifyMongoEnvironment(cluster: string): ResourceEnvironment {
  const normalized = cleanLabel(cluster).toLocaleLowerCase();
  const segment = (value: string) => new RegExp(`(?:^|[^a-z0-9])${value}(?:$|[^a-z0-9])`, "i").test(normalized);

  if (segment("dev(?:elopment)?") || segment("nonprod") || segment("staging")) return "staging";
  if (segment("production")) return "production";
  return "unclassified";
}

export function normalizeMongoDomain(uri: string): string | undefined {
  const match = uri.trim().match(/^mongodb(?:\+srv)?:\/\//i);
  if (!match) return undefined;

  let authority = uri.trim().slice(match[0].length).split(/[/?#]/, 1)[0];
  const credentials = authority.lastIndexOf("@");
  if (credentials >= 0) authority = authority.slice(credentials + 1);

  const firstHost = authority.split(",", 1)[0]?.trim();
  if (!firstHost || firstHost.startsWith("[")) return undefined;
  const domain = firstHost.replace(/:\d+$/, "").replace(/\.$/, "").toLocaleLowerCase();
  if (!/^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(domain)) {
    return undefined;
  }
  return domain;
}

function collectMongoUris(value: unknown, path: string[], found: Array<{ type: string; uri: string }>): void {
  if (typeof value === "string") {
    if (/^mongodb(?:\+srv)?:\/\//i.test(value)) {
      found.push({ type: path.join(".") || "connection", uri: redactMongoCredentials(value) });
    }
    return;
  }

  if (Array.isArray(value)) {
    value.forEach((entry, index) => collectMongoUris(entry, [...path, String(index)], found));
    return;
  }

  if (value && typeof value === "object") {
    Object.entries(value as Record<string, unknown>).forEach(([key, entry]) =>
      collectMongoUris(entry, [...path, key], found),
    );
  }
}

export function buildMongoConnections(rows: MongoRow[], sourceConnection = "mongodbatlas"): MongoConnection[] {
  const clusterCounts = new Map<string, number>();
  rows.forEach((row) => {
    const key = cleanLabel(row.name).toLocaleLowerCase();
    clusterCounts.set(key, (clusterCounts.get(key) ?? 0) + 1);
  });

  return rows.flatMap((row) => {
    const values: Array<{ type: string; uri: string }> = [];
    collectMongoUris(row.connection_strings, [], values);
    collectMongoUris(row.mongo_uri, ["mongoUri"], values);
    collectMongoUris(row.mongo_uri_with_options, ["mongoUriWithOptions"], values);
    collectMongoUris(row.srv_address, ["srvAddress"], values);

    const unique = new Map<string, { type: string; domain: string }>();
    values.forEach((entry) => {
      const domain = normalizeMongoDomain(entry.uri);
      if (domain && !unique.has(domain)) unique.set(domain, { type: entry.type, domain });
    });

    const cluster = cleanLabel(row.name) || "Unnamed MongoDB cluster";
    const projectId = row.project_id ?? "unknown";
    const environment = classifyMongoEnvironment(cluster);
    const state = row.state_name ?? "unknown";
    const needsQualifier = unique.size > 1 || (clusterCounts.get(cluster.toLocaleLowerCase()) ?? 0) > 1;

    return [...unique.values()].map((entry) => ({
      key: `mongodb:${projectId}:${cluster}:${entry.domain}`,
      kind: "mongodb" as const,
      environment,
      accountId: projectId,
      region: "MongoDB Atlas",
      sourceConnection,
      sourceId: cluster,
      displayName: cluster,
      resourceName: needsQualifier ? `${cluster} (${entry.domain})` : cluster,
      address: entry.domain,
      status: state,
      detail: entry.type,
      cluster,
      projectId,
      state,
      connectionType: entry.type,
      domain: entry.domain,
    }));
  }).sort((left, right) => {
    const environmentOrder = { production: 0, staging: 1, unclassified: 2 } as const;
    return (
      environmentOrder[left.environment] - environmentOrder[right.environment] ||
      left.cluster.localeCompare(right.cluster) ||
      left.domain.localeCompare(right.domain)
    );
  });
}

export function normalizeAddress(address: string): string {
  return address.trim().toLocaleLowerCase().replace(/\.$/, "");
}

export function summarizeBulkTarget(
  resources: NetBirdResource[],
  networkId: string,
  groupIds: readonly string[],
): BulkTargetSummary {
  const selectedGroups = new Set(groupIds);
  const networkResources = new Set(resources.filter((resource) => resource.networkId === networkId).map((resource) => resource.id));
  const groupResources = new Set(
    resources
      .filter((resource) => resource.groups?.some((group) => selectedGroups.has(group.id)))
      .map((resource) => resource.id),
  );

  return {
    networkResourceCount: networkResources.size,
    selectedGroupResourceCount: groupResources.size,
  };
}

interface ExistingNetBirdResource {
  name: string;
  address: string;
  networkName?: string;
  groups?: Array<{ id: string; name: string }>;
}

function existingResourceLocation(resource: ExistingNetBirdResource): string {
  const networkName = cleanLabel(resource.networkName);
  const groupNames = resource.groups?.map((group) => cleanLabel(group.name)).filter(Boolean) ?? [];
  const network = networkName ? ` in network ${networkName}` : "";
  const groups = groupNames.length ? ` (groups: ${groupNames.join(", ")})` : "";
  return `${network}${groups}`;
}

export function preflightBulkResources(
  resources: BulkResourceInput[],
  existing: ExistingNetBirdResource[],
): { ready: BulkResourceInput[]; results: BulkResult[] } {
  const existingNames = new Map(existing.map((resource) => [cleanLabel(resource.name).toLocaleLowerCase(), resource]));
  const existingAddresses = new Map(existing.map((resource) => [normalizeAddress(resource.address), resource]));
  const incomingNames = new Set<string>();
  const incomingAddresses = new Set<string>();
  const ready: BulkResourceInput[] = [];
  const results: BulkResult[] = [];

  for (const resource of resources) {
    const normalizedName = cleanLabel(resource.name).toLocaleLowerCase();
    const normalizedAddress = normalizeAddress(resource.address);
    let reason: string | undefined;

    const nameMatch = existingNames.get(normalizedName);
    const addressMatch = existingAddresses.get(normalizedAddress);

    if (nameMatch) reason = `A NetBird resource already uses this name${existingResourceLocation(nameMatch)}.`;
    else if (addressMatch) reason = `This address already exists in NetBird${existingResourceLocation(addressMatch)}.`;
    else if (incomingNames.has(normalizedName)) reason = "Another selected resource uses this name.";
    else if (incomingAddresses.has(normalizedAddress)) reason = "Another selected resource uses this address.";

    if (reason) {
      results.push({ key: resource.key, name: resource.name, address: resource.address, status: "duplicate", reason });
      continue;
    }

    incomingNames.add(normalizedName);
    incomingAddresses.add(normalizedAddress);
    ready.push({ ...resource, name: cleanLabel(resource.name), address: normalizedAddress });
    results.push({ key: resource.key, name: resource.name, address: resource.address, status: "ready" });
  }

  return { ready, results };
}
