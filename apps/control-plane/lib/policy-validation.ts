import type {
  CreatePolicyRequest,
  NetBirdPolicyAction,
  NetBirdPolicyProtocol,
  NetBirdPolicyRuleInput,
  NetBirdResourceType,
} from "@/lib/types";

const MAX_NAME_LENGTH = 240;
const MAX_DESCRIPTION_LENGTH = 1_000;
const MAX_RULES = 50;
const policyActions = new Set<NetBirdPolicyAction>(["accept", "drop"]);
const policyProtocols = new Set<NetBirdPolicyProtocol>(["all", "tcp", "udp", "icmp", "netbird-ssh"]);
const resourceTypes = new Set<NetBirdResourceType>(["host", "subnet", "domain", "peer"]);

function text(value: unknown, label: string, maximum: number, required = true): string {
  if (typeof value !== "string") {
    if (!required && value === undefined) return "";
    throw new Error(`${label} must be a string.`);
  }
  const normalized = value.replace(/\s+/g, " ").trim();
  if (required && !normalized) throw new Error(`${label} is required.`);
  if (normalized.length > maximum) throw new Error(`${label} must be ${maximum.toLocaleString()} characters or fewer.`);
  return normalized;
}

function boolean(value: unknown, label: string): boolean {
  if (typeof value !== "boolean") throw new Error(`${label} must be true or false.`);
  return value;
}

function ids(value: unknown, label: string): string[] | undefined {
  if (value === undefined) return undefined;
  if (!Array.isArray(value) || !value.length) throw new Error(`${label} must contain at least one group ID.`);
  const unique = [...new Set(value.map((id) => text(id, `${label} ID`, 256)))];
  return unique;
}

function optionalIds(value: unknown, label: string): string[] {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value)) throw new Error(`${label} must be an array.`);
  return [...new Set(value.map((id) => text(id, `${label} ID`, 256)))];
}

function resource(value: unknown, label: string): { id: string; type: NetBirdResourceType } | undefined {
  if (value === undefined) return undefined;
  if (!value || typeof value !== "object") throw new Error(`${label} must be a NetBird resource.`);
  const item = value as Record<string, unknown>;
  const id = text(item.id, `${label} ID`, 256);
  if (typeof item.type !== "string" || !resourceTypes.has(item.type as NetBirdResourceType)) {
    throw new Error(`${label} type is invalid.`);
  }
  return { id, type: item.type as NetBirdResourceType };
}

function ports(value: unknown, label: string): string[] | undefined {
  if (value === undefined) return undefined;
  if (!Array.isArray(value)) throw new Error(`${label} must be an array.`);
  const unique = [...new Set(value.map((port) => text(port, "Port", 5)))];
  unique.forEach((port) => {
    const number = Number(port);
    if (!Number.isInteger(number) || number < 1 || number > 65_535) throw new Error("Ports must be between 1 and 65535.");
  });
  return unique;
}

function portRanges(value: unknown): Array<{ start: number; end: number }> | undefined {
  if (value === undefined) return undefined;
  if (!Array.isArray(value)) throw new Error("Port ranges must be an array.");
  const unique = new Map<string, { start: number; end: number }>();
  value.forEach((range) => {
    if (!range || typeof range !== "object") throw new Error("Each port range must have a start and end port.");
    const item = range as Record<string, unknown>;
    if (!Number.isInteger(item.start) || !Number.isInteger(item.end)) throw new Error("Port range values must be integers.");
    const start = item.start as number;
    const end = item.end as number;
    if (start < 1 || end > 65_535 || start > end) throw new Error("Port ranges must be between 1 and 65535 with start before end.");
    unique.set(`${start}:${end}`, { start, end });
  });
  return [...unique.values()];
}

function endpoint(
  groups: string[] | undefined,
  selectedResource: { id: string; type: NetBirdResourceType } | undefined,
  label: string,
): void {
  if (groups && selectedResource) throw new Error(`${label} must use groups or one resource, not both.`);
  if (!groups && !selectedResource) throw new Error(`${label} requires at least one group or resource.`);
}

function authorizedGroups(value: unknown): Record<string, string[]> | undefined {
  if (value === undefined || value === null) return undefined;
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Authorized groups must be an object.");
  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>).map(([groupId, users]) => [
      text(groupId, "Authorized group ID", 256),
      optionalIds(users, "Authorized users"),
    ]),
  );
}

function rule(value: unknown, index: number): NetBirdPolicyRuleInput {
  if (!value || typeof value !== "object") throw new Error(`Rule ${index + 1} must be an object.`);
  const item = value as Record<string, unknown>;
  const protocol = item.protocol as NetBirdPolicyProtocol;
  if (!policyProtocols.has(protocol)) throw new Error(`Rule ${index + 1} protocol is invalid.`);
  const action = item.action as NetBirdPolicyAction;
  if (!policyActions.has(action)) throw new Error(`Rule ${index + 1} action is invalid.`);

  const sources = ids(item.sources, `Rule ${index + 1} sources`);
  const sourceResource = resource(item.sourceResource, `Rule ${index + 1} source resource`);
  const destinations = ids(item.destinations, `Rule ${index + 1} destinations`);
  const destinationResource = resource(item.destinationResource, `Rule ${index + 1} destination resource`);
  endpoint(sources, sourceResource, `Rule ${index + 1} source`);
  endpoint(destinations, destinationResource, `Rule ${index + 1} destination`);

  const directPorts = ports(item.ports, "Ports");
  const ranges = portRanges(item.port_ranges);
  const preservedAuthorizedGroups = authorizedGroups(item.authorized_groups);
  if ((directPorts?.length || ranges?.length) && protocol !== "tcp" && protocol !== "udp") {
    throw new Error(`Rule ${index + 1} ports are only supported for TCP or UDP.`);
  }

  return {
    ...(item.id === undefined ? {} : { id: text(item.id, `Rule ${index + 1} ID`, 256) }),
    name: text(item.name, `Rule ${index + 1} name`, MAX_NAME_LENGTH),
    description: text(item.description, `Rule ${index + 1} description`, MAX_DESCRIPTION_LENGTH, false),
    enabled: boolean(item.enabled, `Rule ${index + 1} enabled`),
    action,
    bidirectional: boolean(item.bidirectional, `Rule ${index + 1} bidirectional`),
    protocol,
    ...(directPorts?.length ? { ports: directPorts } : {}),
    ...(ranges?.length ? { port_ranges: ranges } : {}),
    ...(preservedAuthorizedGroups ? { authorized_groups: preservedAuthorizedGroups } : {}),
    ...(sources ? { sources } : {}),
    ...(sourceResource ? { sourceResource } : {}),
    ...(destinations ? { destinations } : {}),
    ...(destinationResource ? { destinationResource } : {}),
  };
}

export function parsePolicyRequest(value: unknown): CreatePolicyRequest {
  if (!value || typeof value !== "object") throw new Error("Request body must be a JSON object.");
  const body = value as Record<string, unknown>;
  if (!Array.isArray(body.rules) || !body.rules.length) throw new Error("Add at least one policy rule.");
  if (body.rules.length > MAX_RULES) throw new Error(`A policy can contain at most ${MAX_RULES} rules.`);

  return {
    name: text(body.name, "Policy name", MAX_NAME_LENGTH),
    description: text(body.description, "Policy description", MAX_DESCRIPTION_LENGTH, false),
    enabled: boolean(body.enabled, "Policy enabled"),
    source_posture_checks: optionalIds(body.source_posture_checks, "Source posture checks"),
    rules: body.rules.map((item, index) => rule(item, index)),
  };
}

export function parsePortInput(value: string): { ports?: string[]; port_ranges?: Array<{ start: number; end: number }> } {
  const tokens = value.split(",").map((token) => token.trim()).filter(Boolean);
  if (!tokens.length) return {};
  const direct: string[] = [];
  const ranges: Array<{ start: number; end: number }> = [];
  tokens.forEach((token) => {
    const match = token.match(/^(\d+)(?:-(\d+))?$/);
    if (!match) throw new Error("Ports must use comma-separated numbers or ranges such as 80,443,1000-2000.");
    const start = Number(match[1]);
    const end = Number(match[2] ?? match[1]);
    if (!Number.isInteger(start) || !Number.isInteger(end) || start < 1 || end > 65_535 || start > end) {
      throw new Error("Ports must be between 1 and 65535 with range starts before range ends.");
    }
    if (start === end) direct.push(String(start));
    else ranges.push({ start, end });
  });
  return {
    ...(direct.length ? { ports: [...new Set(direct)] } : {}),
    ...(ranges.length ? { port_ranges: [...new Map(ranges.map((range) => [`${range.start}:${range.end}`, range])).values()] } : {}),
  };
}
