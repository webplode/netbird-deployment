import "server-only";

import { getDemoNetBirdSnapshot } from "@/lib/demo";
import { cleanLabel, normalizeAddress, preflightBulkResources, summarizeBulkTarget } from "@/lib/inventory-utils";
import type {
  BulkRequest,
  BulkResponse,
  BulkResult,
  BulkResultStatus,
  CreateGroupRequest,
  CreateGroupResponse,
  CreateNetworkRequest,
  CreateNetworkResponse,
  CreatePolicyRequest,
  CreatePolicyResponse,
  NetBirdGroup,
  NetBirdNetwork,
  NetBirdPeer,
  NetBirdPolicy,
  NetBirdResource,
  NetBirdRouter,
  NetBirdSnapshot,
  NetBirdUser,
  UpdateRouterRequest,
  UpdateRouterResponse,
} from "@/lib/types";

const DEFAULT_API_URL = "https://nbvpn.sleek.com";

declare global {
  var sleekBulkResourceLocks: Map<string, Promise<void>> | undefined;
}

export class NetBirdApiError extends Error {
  constructor(
    message: string,
    public readonly status: number,
    public readonly requestId?: string,
  ) {
    super(message);
    this.name = "NetBirdApiError";
  }
}

function apiUrl(): string {
  const configured = (process.env.NETBIRD_API_URL || DEFAULT_API_URL).replace(/\/$/, "");
  const parsed = new URL(configured);
  if (!new Set(["http:", "https:"]).has(parsed.protocol)) {
    throw new Error("NETBIRD_API_URL must use HTTP or HTTPS.");
  }
  return parsed.toString().replace(/\/$/, "");
}

export function isNetBirdDemoMode(): boolean {
  return process.env.NETBIRD_DEMO_MODE === "true" || !process.env.NETBIRD_API_TOKEN?.trim();
}

function authorizationHeader(): string {
  const token = process.env.NETBIRD_API_TOKEN?.trim();
  if (!token) throw new Error("NETBIRD_API_TOKEN is required for live NetBird requests.");
  if (/^(Token|Bearer)\s/i.test(token)) return token;
  return `Token ${token}`;
}

async function requestJson<T>(path: string, init: RequestInit = {}): Promise<T> {
  const timeout = Number(process.env.NETBIRD_REQUEST_TIMEOUT_MS || 15_000);
  const response = await fetch(`${apiUrl()}${path}`, {
    ...init,
    cache: "no-store",
    signal: AbortSignal.timeout(Number.isFinite(timeout) ? timeout : 15_000),
    headers: {
      Accept: "application/json",
      Authorization: authorizationHeader(),
      ...(init.body ? { "Content-Type": "application/json" } : {}),
      ...init.headers,
    },
  });

  const body = await response.text();
  if (!response.ok) {
    const detail = body.trim().slice(0, 400);
    throw new NetBirdApiError(
      `NetBird ${response.status}: ${detail || response.statusText}`,
      response.status,
      response.headers.get("x-request-id") ?? undefined,
    );
  }

  return (body ? JSON.parse(body) : undefined) as T;
}

async function optionalList<T>(path: string, label: string, warnings: string[]): Promise<T[]> {
  try {
    return (await requestJson<T[] | null>(path)) ?? [];
  } catch (error) {
    warnings.push(`${label} could not be loaded: ${error instanceof Error ? error.message : "Unknown error"}`);
    return [];
  }
}

function attachRouterNetworks(routers: NetBirdRouter[], networks: NetBirdNetwork[]): NetBirdRouter[] {
  const ownership = new Map<string, NetBirdNetwork>();
  networks.forEach((network) => network.routers?.forEach((routerId) => ownership.set(routerId, network)));
  return routers.map((router) => {
    const network = ownership.get(router.id);
    return network ? { ...router, networkId: network.id, networkName: network.name } : router;
  });
}

async function liveResources(networks: NetBirdNetwork[], warnings: string[]): Promise<NetBirdResource[]> {
  const settled = await Promise.allSettled(
    networks.map(async (network) => {
      const resources = await requestJson<Omit<NetBirdResource, "networkId" | "networkName">[] | null>(
        `/api/networks/${encodeURIComponent(network.id)}/resources`,
      );
      return (resources ?? []).map((resource) => ({
        ...resource,
        networkId: network.id,
        networkName: network.name,
      }));
    }),
  );

  return settled.flatMap((result, index) => {
    if (result.status === "fulfilled") return result.value;
    warnings.push(
      `${networks[index].name} resources could not be loaded: ${result.reason instanceof Error ? result.reason.message : "Unknown error"}`,
    );
    return [];
  });
}

export async function getNetBirdSnapshot(): Promise<NetBirdSnapshot> {
  const baseUrl = apiUrl();
  if (isNetBirdDemoMode()) return getDemoNetBirdSnapshot(baseUrl);

  const warnings: string[] = [];
  const networks = await requestJson<NetBirdNetwork[]>("/api/networks");
  const [groups, policies, peers, users, routers, resources] = await Promise.all([
    optionalList<NetBirdGroup>("/api/groups", "Groups", warnings),
    optionalList<NetBirdPolicy>("/api/policies", "Policies", warnings),
    optionalList<NetBirdPeer>("/api/peers", "Peers", warnings),
    optionalList<NetBirdUser>("/api/users", "Users", warnings),
    optionalList<NetBirdRouter>("/api/networks/routers", "Routers", warnings),
    liveResources(networks, warnings),
  ]);

  return {
    mode: "live",
    generatedAt: new Date().toISOString(),
    apiUrl: baseUrl,
    networks,
    resources,
    routers: attachRouterNetworks(routers, networks),
    peers,
    groups,
    users,
    policies,
    warnings,
  };
}

export async function createNetBirdNetwork(input: CreateNetworkRequest): Promise<CreateNetworkResponse> {
  if (isNetBirdDemoMode()) {
    throw new NetBirdApiError("Configure the live NetBird API before creating a network.", 400);
  }

  const networks = (await requestJson<NetBirdNetwork[] | null>("/api/networks")) ?? [];
  if (networks.some((network) => network.name.trim().toLocaleLowerCase() === input.name.toLocaleLowerCase())) {
    throw new NetBirdApiError("A NetBird network already uses this name.", 409);
  }

  const network = await requestJson<NetBirdNetwork>("/api/networks", {
    method: "POST",
    body: JSON.stringify({
      name: input.name,
      description: input.description,
    }),
  });
  return { mode: "live", network };
}

export async function createNetBirdGroup(input: CreateGroupRequest): Promise<CreateGroupResponse> {
  if (isNetBirdDemoMode()) {
    throw new NetBirdApiError("Configure the live NetBird API before creating a resource group.", 400);
  }

  const groups = (await requestJson<NetBirdGroup[] | null>("/api/groups")) ?? [];
  if (groups.some((group) => group.name.trim().toLocaleLowerCase() === input.name.toLocaleLowerCase())) {
    throw new NetBirdApiError("A NetBird resource group already uses this name.", 409);
  }

  const group = await requestJson<NetBirdGroup>("/api/groups", {
    method: "POST",
    body: JSON.stringify({ name: input.name }),
  });
  return { mode: "live", group };
}

export async function updateNetBirdRouter(routerId: string, input: UpdateRouterRequest): Promise<UpdateRouterResponse> {
  if (isNetBirdDemoMode()) {
    throw new NetBirdApiError("Configure the live NetBird API before updating a router.", 400);
  }

  const path = `/api/networks/${encodeURIComponent(input.networkId)}/routers/${encodeURIComponent(routerId)}`;
  const router = await requestJson<NetBirdRouter>(path, {
    method: "PUT",
    body: JSON.stringify({
      metric: input.metric,
      masquerade: input.masquerade,
      enabled: input.enabled,
      ...(input.peer ? { peer: input.peer } : { peer_groups: input.peer_groups }),
    }),
  });
  return { mode: "live", router: { ...router, networkId: input.networkId } };
}

export async function createNetBirdPolicy(input: CreatePolicyRequest): Promise<CreatePolicyResponse> {
  if (isNetBirdDemoMode()) {
    throw new NetBirdApiError("Configure the live NetBird API before creating a policy.", 400);
  }

  const policies = (await requestJson<NetBirdPolicy[] | null>("/api/policies")) ?? [];
  if (policies.some((policy) => policy.name.trim().toLocaleLowerCase() === input.name.toLocaleLowerCase())) {
    throw new NetBirdApiError("A NetBird policy already uses this name.", 409);
  }

  const policy = await requestJson<NetBirdPolicy>("/api/policies", {
    method: "POST",
    body: JSON.stringify(input),
  });
  return { mode: "live", policy };
}

export async function updateNetBirdPolicy(policyId: string, input: CreatePolicyRequest): Promise<CreatePolicyResponse> {
  if (isNetBirdDemoMode()) {
    throw new NetBirdApiError("Configure the live NetBird API before updating a policy.", 400);
  }

  const policies = (await requestJson<NetBirdPolicy[] | null>("/api/policies")) ?? [];
  if (!policies.some((policy) => policy.id === policyId)) {
    throw new NetBirdApiError("The NetBird policy no longer exists.", 404);
  }
  if (policies.some((policy) => policy.id !== policyId && policy.name.trim().toLocaleLowerCase() === input.name.toLocaleLowerCase())) {
    throw new NetBirdApiError("A NetBird policy already uses this name.", 409);
  }

  const policy = await requestJson<NetBirdPolicy>(`/api/policies/${encodeURIComponent(policyId)}`, {
    method: "PUT",
    body: JSON.stringify(input),
  });
  return { mode: "live", policy };
}

interface BulkInventory {
  networks: NetBirdNetwork[];
  groups: NetBirdGroup[];
  resources: NetBirdResource[];
}

async function liveBulkInventory(): Promise<BulkInventory> {
  const networks = await requestJson<NetBirdNetwork[]>("/api/networks");
  const [groups, resources] = await Promise.all([
    requestJson<NetBirdGroup[] | null>("/api/groups"),
    (async () => {
      const warnings: string[] = [];
      const resources = await liveResources(networks, warnings);
      if (warnings.length) throw new Error(warnings.join(" "));
      return resources;
    })(),
  ]);

  return { networks, groups: groups ?? [], resources };
}

function validateBulkTarget(request: BulkRequest, inventory: BulkInventory): void {
  if (!inventory.networks.some((network) => network.id === request.networkId)) {
    throw new Error("The selected NetBird network no longer exists. Refresh and choose another network.");
  }

  const existingGroupIds = new Set(inventory.groups.map((group) => group.id));
  const missingGroups = request.groupIds.filter((groupId) => !existingGroupIds.has(groupId));
  if (missingGroups.length) {
    throw new Error("One or more selected NetBird resource groups no longer exist. Refresh and choose valid groups.");
  }
}

function bulkLockKeys(resources: BulkRequest["resources"]): string[] {
  return [...new Set(resources.flatMap((resource) => [
    `name:${cleanLabel(resource.name).toLocaleLowerCase()}`,
    `address:${normalizeAddress(resource.address)}`,
  ]))].sort();
}

async function withBulkResourceLocks<T>(resources: BulkRequest["resources"], work: () => Promise<T>): Promise<T> {
  const locks = globalThis.sleekBulkResourceLocks ??= new Map<string, Promise<void>>();
  const waits: Promise<void>[] = [];
  const registrations = bulkLockKeys(resources).map((key) => {
    const previous = locks.get(key);
    let release!: () => void;
    const lock = new Promise<void>((resolve) => { release = resolve; });
    locks.set(key, lock);
    if (previous) waits.push(previous);
    return { key, lock, release };
  });

  await Promise.all(waits);
  try {
    return await work();
  } finally {
    registrations.forEach(({ key, lock, release }) => {
      release();
      if (locks.get(key) === lock) locks.delete(key);
    });
  }
}

async function prepareBulk(request: BulkRequest, demo: boolean): Promise<{
  target: ReturnType<typeof summarizeBulkTarget>;
  preflight: ReturnType<typeof preflightBulkResources>;
}> {
  const inventory = demo
    ? (() => {
        const snapshot = getDemoNetBirdSnapshot(apiUrl());
        return { networks: snapshot.networks, groups: snapshot.groups, resources: snapshot.resources };
      })()
    : await liveBulkInventory();
  validateBulkTarget(request, inventory);
  return {
    target: summarizeBulkTarget(inventory.resources, request.networkId, request.groupIds),
    preflight: preflightBulkResources(request.resources, inventory.resources),
  };
}

async function mapWithLimit<T, R>(items: T[], limit: number, worker: (item: T) => Promise<R>): Promise<R[]> {
  const output = new Array<R>(items.length);
  let next = 0;

  async function run(): Promise<void> {
    while (next < items.length) {
      const index = next++;
      output[index] = await worker(items[index]);
    }
  }

  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, () => run()));
  return output;
}

function summary(results: BulkResult[]): Record<BulkResultStatus, number> {
  const counts: Record<BulkResultStatus, number> = {
    ready: 0,
    duplicate: 0,
    created: 0,
    failed: 0,
    simulated: 0,
  };
  results.forEach((result) => counts[result.status]++);
  return counts;
}

function resourceDescription(resource: BulkRequest["resources"][number]): string {
  if (resource.kind === "mongodb") {
    return `Discovered by Steampipe from ${resource.environment} MongoDB Atlas, project ${resource.accountId}.`;
  }
  return `Discovered by Steampipe from ${resource.environment} ${resource.kind.toUpperCase()} in ${resource.region}, account ${resource.accountId}.`;
}

export async function bulkCreateResources(request: BulkRequest): Promise<BulkResponse> {
  const demo = isNetBirdDemoMode();
  if (request.dryRun) {
    const { target, preflight } = await prepareBulk(request, demo);
    return {
      mode: demo ? "demo" : "live",
      dryRun: true,
      networkId: request.networkId,
      target,
      summary: summary(preflight.results),
      results: preflight.results,
    };
  }

  const create = async (): Promise<BulkResponse> => {
    const { target, preflight } = await prepareBulk(request, demo);
    const outcomes = demo
      ? preflight.ready.map<BulkResult>((resource) => ({
          key: resource.key,
          name: resource.name,
          address: normalizeAddress(resource.address),
          status: "simulated",
          reason: "Demo mode is active. No NetBird change was sent.",
        }))
      : await mapWithLimit(preflight.ready, 4, async (resource): Promise<BulkResult> => {
          try {
            const created = await requestJson<{ id: string }>(
              `/api/networks/${encodeURIComponent(request.networkId)}/resources`,
              {
                method: "POST",
                body: JSON.stringify({
                  name: resource.name,
                  description: resourceDescription(resource),
                  address: normalizeAddress(resource.address),
                  enabled: true,
                  groups: request.groupIds,
                }),
              },
            );
            return {
              key: resource.key,
              name: resource.name,
              address: resource.address,
              status: "created",
              resourceId: created.id,
            };
          } catch (error) {
            return {
              key: resource.key,
              name: resource.name,
              address: resource.address,
              status: "failed",
              reason: error instanceof Error ? error.message : "Unknown NetBird error",
            };
          }
        });

    const outcomeByKey = new Map(outcomes.map((outcome) => [outcome.key, outcome]));
    const results = preflight.results.map((result) => outcomeByKey.get(result.key) ?? result);

    return {
      mode: demo ? "demo" : "live",
      dryRun: false,
      networkId: request.networkId,
      target,
      summary: summary(results),
      results,
    };
  };

  return demo ? create() : withBulkResourceLocks(request.resources, create);
}
