export type AwsEnvironment = "production" | "staging";
export type AwsResourceKind = "ec2" | "rds";
export type ResourceEnvironment = AwsEnvironment | "unclassified";
export type ResourceKind = AwsResourceKind | "mongodb";

export interface ResourceCandidate {
  key: string;
  kind: ResourceKind;
  environment: ResourceEnvironment;
  accountId: string;
  region: string;
  sourceConnection: string;
  sourceId: string;
  displayName: string;
  resourceName: string;
  address: string;
  status: string;
  detail: string;
}

export interface MongoConnection extends ResourceCandidate {
  kind: "mongodb";
  cluster: string;
  projectId: string;
  state: string;
  connectionType: string;
  domain: string;
}

export interface InventoryResponse {
  mode: "live" | "demo";
  generatedAt: string;
  resources: ResourceCandidate[];
  mongoConnections: MongoConnection[];
  warnings: string[];
}

export interface NetBirdNetwork {
  id: string;
  name: string;
  description?: string;
  routers?: string[];
  resources?: string[];
  policies?: string[];
  routing_peers_count?: number;
}

export interface NetBirdUser {
  id: string;
  email: string;
  name: string;
  role: string;
  status: string;
  is_service_user?: boolean;
  is_blocked?: boolean;
  last_login?: string;
  auto_groups?: string[];
}

export interface NetBirdGroup {
  id: string;
  name: string;
  issued?: "api" | "integration" | "jwt";
  peers_count?: number;
  resources_count?: number;
  peers?: Array<{ id: string; name: string }> | null;
  resources?: Array<{ id: string; type: NetBirdResourceType }> | null;
}

export type NetBirdResourceType = "host" | "subnet" | "domain" | "peer";

export interface NetBirdPolicyRule {
  id?: string;
  name?: string;
  description?: string;
  enabled?: boolean;
  action?: string;
  bidirectional?: boolean;
  protocol?: string;
  ports?: string[] | null;
  port_ranges?: Array<{ start: number; end: number }> | null;
  authorized_groups?: Record<string, string[]> | null;
  sources?: Array<{ id: string; name: string }> | null;
  sourceResource?: { id: string; type: NetBirdResourceType } | null;
  destinations?: Array<{ id: string; name: string }> | null;
  destinationResource?: { id: string; type: NetBirdResourceType } | null;
}

export interface NetBirdPolicy {
  id: string;
  name: string;
  description?: string;
  enabled?: boolean;
  source_posture_checks?: string[] | null;
  rules?: NetBirdPolicyRule[];
}

export interface NetBirdPeer {
  id: string;
  name: string;
  hostname?: string;
  ip?: string;
  connected?: boolean;
  os?: string;
  version?: string;
  user_id?: string;
  groups?: Array<{ id: string; name: string }>;
}

export interface NetBirdResource {
  id: string;
  name: string;
  description?: string;
  address: string;
  enabled: boolean;
  type?: NetBirdResourceType;
  groups?: Array<{ id: string; name: string }>;
  networkId: string;
  networkName: string;
}

export interface NetBirdRouter {
  id: string;
  peer?: string;
  peer_groups?: string[];
  metric?: number;
  masquerade?: boolean;
  enabled?: boolean;
  networkId?: string;
  networkName?: string;
}

export interface UpdateRouterRequest {
  networkId: string;
  peer?: string;
  peer_groups?: string[];
  metric: number;
  masquerade: boolean;
  enabled: boolean;
}

export interface UpdateRouterResponse {
  mode: "live";
  router: NetBirdRouter;
}

export interface NetBirdSnapshot {
  mode: "live" | "demo";
  generatedAt: string;
  apiUrl: string;
  networks: NetBirdNetwork[];
  resources: NetBirdResource[];
  routers: NetBirdRouter[];
  peers: NetBirdPeer[];
  groups: NetBirdGroup[];
  users: NetBirdUser[];
  policies: NetBirdPolicy[];
  warnings: string[];
}

export interface BulkResourceInput {
  key: string;
  name: string;
  address: string;
  kind: ResourceKind;
  environment: ResourceEnvironment;
  accountId: string;
  region: string;
}

export interface BulkRequest {
  networkId: string;
  groupIds: string[];
  resources: BulkResourceInput[];
  dryRun: boolean;
}

export type BulkResultStatus =
  | "ready"
  | "duplicate"
  | "created"
  | "failed"
  | "simulated";

export interface BulkResult {
  key: string;
  name: string;
  address: string;
  status: BulkResultStatus;
  reason?: string;
  resourceId?: string;
}

export interface BulkTargetSummary {
  networkResourceCount: number;
  selectedGroupResourceCount: number;
}

export interface BulkResponse {
  mode: "live" | "demo";
  dryRun: boolean;
  networkId: string;
  target: BulkTargetSummary;
  summary: Record<BulkResultStatus, number>;
  results: BulkResult[];
}

export interface CreateNetworkRequest {
  name: string;
  description: string;
}

export interface CreateNetworkResponse {
  mode: "live";
  network: NetBirdNetwork;
}

export interface CreateGroupRequest {
  name: string;
}

export interface CreateGroupResponse {
  mode: "live";
  group: NetBirdGroup;
}

export type NetBirdPolicyAction = "accept" | "drop";
export type NetBirdPolicyProtocol = "all" | "tcp" | "udp" | "icmp" | "netbird-ssh";

export interface NetBirdPolicyRuleInput {
  id?: string;
  name: string;
  description: string;
  enabled: boolean;
  action: NetBirdPolicyAction;
  bidirectional: boolean;
  protocol: NetBirdPolicyProtocol;
  ports?: string[];
  port_ranges?: Array<{ start: number; end: number }>;
  authorized_groups?: Record<string, string[]>;
  sources?: string[];
  sourceResource?: { id: string; type: NetBirdResourceType };
  destinations?: string[];
  destinationResource?: { id: string; type: NetBirdResourceType };
}

export interface CreatePolicyRequest {
  name: string;
  description: string;
  enabled: boolean;
  source_posture_checks: string[];
  rules: NetBirdPolicyRuleInput[];
}

export interface CreatePolicyResponse {
  mode: "live";
  policy: NetBirdPolicy;
}
