"use client";

import { useEffect, useMemo, useState } from "react";
import {
  AlertTriangle,
  ArrowRight,
  Check,
  ChevronLeft,
  ChevronRight,
  ClipboardCheck,
  Cloud,
  Copy,
  Database,
  Network,
  Pencil,
  Plus,
  Router,
  Search,
  Server,
  ShieldCheck,
  Trash2,
  Users,
  X,
} from "lucide-react";
import type { ViewId } from "@/components/control-plane";
import type {
  BulkRequest,
  BulkResponse,
  BulkResultStatus,
  CreateGroupRequest,
  CreateGroupResponse,
  CreateNetworkRequest,
  CreateNetworkResponse,
  CreatePolicyRequest,
  CreatePolicyResponse,
  InventoryResponse,
  MongoConnection,
  NetBirdGroup,
  NetBirdPeer,
  NetBirdPolicy,
  NetBirdPolicyAction,
  NetBirdPolicyProtocol,
  NetBirdPolicyRule,
  NetBirdPolicyRuleInput,
  NetBirdResource,
  NetBirdResourceType,
  NetBirdRouter,
  NetBirdSnapshot,
  NetBirdUser,
  ResourceCandidate,
  ResourceEnvironment,
  UpdateRouterRequest,
  UpdateRouterResponse,
} from "@/lib/types";
import { summarizeBulkTarget } from "@/lib/inventory-utils";
import { parsePortInput } from "@/lib/policy-validation";

const PAGE_SIZE = 25;

function classNames(...values: Array<string | false | null | undefined>): string {
  return values.filter(Boolean).join(" ");
}

function StatusBadge({ value, tone }: { value: string; tone?: "success" | "danger" | "warning" | "neutral" | "info" }) {
  return <span className={classNames("status-badge", tone ? `is-${tone}` : undefined)}>{value}</span>;
}

function ErrorState({ title, message }: { title: string; message: string }) {
  return (
    <div className="state-panel is-error" role="alert">
      <AlertTriangle size={22} />
      <div><strong>{title}</strong><p>{message}</p></div>
    </div>
  );
}

function EmptyState({ title, message, action }: { title: string; message: string; action?: React.ReactNode }) {
  return (
    <div className="state-panel">
      <Database size={22} />
      <div><strong>{title}</strong><p>{message}</p>{action}</div>
    </div>
  );
}

function TableSkeleton({ rows = 7 }: { rows?: number }) {
  return (
    <div className="skeleton-table" aria-label="Loading">
      {Array.from({ length: rows }, (_, index) => <span key={index} />)}
    </div>
  );
}

function Pagination({ page, pages, onChange }: { page: number; pages: number; onChange: (page: number) => void }) {
  if (pages <= 1) return null;
  return (
    <div className="pagination">
      <span>Page {page + 1} of {pages}</span>
      <div>
        <button className="icon-button" aria-label="Previous page" disabled={page === 0} onClick={() => onChange(page - 1)}><ChevronLeft size={17} /></button>
        <button className="icon-button" aria-label="Next page" disabled={page + 1 >= pages} onClick={() => onChange(page + 1)}><ChevronRight size={17} /></button>
      </div>
    </div>
  );
}

function environmentTone(environment: string): "danger" | "info" | "neutral" {
  if (environment === "production") return "danger";
  if (environment === "staging") return "info";
  return "neutral";
}

export function OverviewView({
  inventory,
  netbird,
  inventoryLoading,
  netbirdLoading,
  inventoryError,
  netbirdError,
  onNavigate,
}: {
  inventory?: InventoryResponse;
  netbird?: NetBirdSnapshot;
  inventoryLoading: boolean;
  netbirdLoading: boolean;
  inventoryError?: string;
  netbirdError?: string;
  onNavigate: (view: ViewId) => void;
}) {
  const resources = inventory?.resources ?? [];
  const production = resources.filter((resource) => resource.environment === "production").length;
  const staging = resources.length - production;
  const connectedPeers = netbird?.peers.filter((peer) => peer.connected).length ?? 0;
  const metrics = [
    { label: "AWS endpoints", value: resources.length, detail: `${production} production, ${staging} staging`, icon: Cloud, loading: inventoryLoading },
    { label: "MongoDB domains", value: inventory?.mongoConnections.length ?? 0, detail: `${new Set(inventory?.mongoConnections.map((item) => item.cluster)).size} Atlas clusters`, icon: Database, loading: inventoryLoading },
    { label: "NetBird resources", value: netbird?.resources.length ?? 0, detail: `${netbird?.networks.length ?? 0} networks`, icon: Network, loading: netbirdLoading },
    { label: "Connected peers", value: connectedPeers, detail: `${netbird?.peers.length ?? 0} total peers`, icon: Server, loading: netbirdLoading },
  ];

  return (
    <div className="view-stack">
      {inventoryError ? <ErrorState title="Steampipe inventory unavailable" message={inventoryError} /> : null}
      {netbirdError ? <ErrorState title="NetBird unavailable" message={netbirdError} /> : null}

      <section className="metric-grid" aria-label="Infrastructure summary">
        {metrics.map(({ label, value, detail, icon: Icon, loading }) => (
          <article className="metric-card" key={label}>
            <div className="metric-icon"><Icon size={19} strokeWidth={1.7} /></div>
            <div><p>{label}</p>{loading ? <span className="skeleton-value" /> : <strong>{value.toLocaleString()}</strong>}<small>{detail}</small></div>
          </article>
        ))}
      </section>

      <div className="overview-grid">
        <section className="panel inventory-summary">
          <div className="panel-heading">
            <div><h2>Resource discovery</h2><p>Addressable AWS services grouped by account boundary.</p></div>
            <button className="text-button" onClick={() => onNavigate("inventory")}>View inventory <ArrowRight size={15} /></button>
          </div>
          {inventoryLoading ? <TableSkeleton rows={5} /> : (
            <div className="environment-summary">
              {(["production", "staging"] as const).map((environment) => {
                const rows = resources.filter((resource) => resource.environment === environment);
                const ec2 = rows.filter((resource) => resource.kind === "ec2").length;
                const rds = rows.length - ec2;
                return (
                  <div className="environment-row" key={environment}>
                    <div><StatusBadge value={environment} tone={environmentTone(environment)} /><span>{new Set(rows.map((row) => row.region)).size} regions</span></div>
                    <div className="environment-counts"><span><strong>{ec2}</strong> EC2</span><span><strong>{rds}</strong> RDS</span><span><strong>{rows.length}</strong> total</span></div>
                  </div>
                );
              })}
            </div>
          )}
        </section>

        <section className="panel network-summary">
          <div className="panel-heading">
            <div><h2>NetBird posture</h2><p>Current routing and policy coverage.</p></div>
            <button className="text-button" onClick={() => onNavigate("netbird")}>Open network <ArrowRight size={15} /></button>
          </div>
          {netbirdLoading ? <TableSkeleton rows={5} /> : netbird ? (
            <dl className="definition-list">
              <div><dt>Networks</dt><dd>{netbird.networks.length}</dd></div>
              <div><dt>Routers enabled</dt><dd>{netbird.routers.filter((router) => router.enabled).length} / {netbird.routers.length}</dd></div>
              <div><dt>Policies enabled</dt><dd>{netbird.policies.filter((policy) => policy.enabled).length} / {netbird.policies.length}</dd></div>
              <div><dt>Resource groups</dt><dd>{netbird.groups.length}</dd></div>
              <div><dt>API mode</dt><dd><StatusBadge value={netbird.mode} tone={netbird.mode === "live" ? "success" : "warning"} /></dd></div>
            </dl>
          ) : <EmptyState title="No NetBird snapshot" message="Configure the API token or reload the page." />}
        </section>
      </div>

      <section className="panel compact-table-panel">
        <div className="panel-heading">
          <div><h2>Ready for NetBird</h2><p>Recent AWS endpoints with generated resource names.</p></div>
          <button className="button button-primary" onClick={() => onNavigate("bulk")}><Plus size={16} /> Bulk add</button>
        </div>
        {inventoryLoading ? <TableSkeleton /> : (
          <div className="table-scroll">
            <table className="data-table">
              <thead><tr><th>Resource</th><th>Generated name</th><th>Environment</th><th>Region</th><th>Status</th></tr></thead>
              <tbody>
                {resources.slice(0, 8).map((resource) => (
                  <tr key={resource.key}>
                    <td><div className="resource-cell"><span className="resource-icon">{resource.kind === "ec2" ? <Server size={16} /> : <Database size={16} />}</span><span><strong>{resource.displayName}</strong><small>{resource.address}</small></span></div></td>
                    <td className="mono-cell">{resource.resourceName}</td>
                    <td><StatusBadge value={resource.environment} tone={environmentTone(resource.environment)} /></td>
                    <td>{resource.region}</td>
                    <td><StatusBadge value={resource.status} tone={resource.status === "running" || resource.status === "available" ? "success" : "neutral"} /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </div>
  );
}

export function InventoryView({ resources, loading, error, selectedKeys, onToggle, onToggleMany, onOpenBulk }: {
  resources: ResourceCandidate[];
  loading: boolean;
  error?: string;
  selectedKeys: Set<string>;
  onToggle: (key: string) => void;
  onToggleMany: (keys: string[], checked: boolean) => void;
  onOpenBulk: () => void;
}) {
  const [environment, setEnvironment] = useState<"all" | "production" | "staging">("all");
  const [kind, setKind] = useState<"all" | "ec2" | "rds">("all");
  const [query, setQuery] = useState("");
  const [page, setPage] = useState(0);

  const filtered = useMemo(() => {
    const search = query.trim().toLocaleLowerCase();
    return resources.filter((resource) =>
      (environment === "all" || resource.environment === environment) &&
      (kind === "all" || resource.kind === kind) &&
      (!search || [resource.displayName, resource.resourceName, resource.address, resource.region, resource.accountId].some((value) => value.toLocaleLowerCase().includes(search))),
    );
  }, [environment, kind, query, resources]);

  const pages = Math.max(1, Math.ceil(filtered.length / PAGE_SIZE));
  const currentPage = Math.min(page, pages - 1);
  const visible = filtered.slice(currentPage * PAGE_SIZE, (currentPage + 1) * PAGE_SIZE);
  const allVisibleSelected = visible.length > 0 && visible.every((resource) => selectedKeys.has(resource.key));
  const allFilteredSelected = filtered.length > 0 && filtered.every((resource) => selectedKeys.has(resource.key));

  function resetPage(action: () => void) {
    action();
    setPage(0);
  }

  if (error) return <ErrorState title="AWS inventory unavailable" message={error} />;

  return (
    <div className="view-stack">
      <section className="toolbar-panel">
        <div className="segmented-control" aria-label="Environment filter">
          {(["all", "production", "staging"] as const).map((value) => <button key={value} className={environment === value ? "is-active" : ""} onClick={() => resetPage(() => setEnvironment(value))}>{value}</button>)}
        </div>
        <div className="segmented-control" aria-label="Resource type filter">
          {(["all", "ec2", "rds"] as const).map((value) => <button key={value} className={kind === value ? "is-active" : ""} onClick={() => resetPage(() => setKind(value))}>{value === "all" ? "All types" : value.toUpperCase()}</button>)}
        </div>
        <label className="search-field"><Search size={16} /><span className="sr-only">Search inventory</span><input value={query} onChange={(event) => resetPage(() => setQuery(event.target.value))} placeholder="Search name, DNS, account, region" /></label>
        <button className="button button-secondary" onClick={() => onToggleMany(filtered.map((resource) => resource.key), !allFilteredSelected)} disabled={!filtered.length || (!allFilteredSelected && selectedKeys.size >= 1000)}><Check size={16} /> {allFilteredSelected ? "Clear filtered" : "Select filtered"}</button>
        <button className="button button-primary" onClick={onOpenBulk} disabled={!selectedKeys.size}><Plus size={16} /> Add selected <span className="button-count">{selectedKeys.size}</span></button>
      </section>

      {selectedKeys.size >= 1000 ? <div className="inline-notice"><AlertTriangle size={16} /> The 1,000-resource batch limit is reached.</div> : null}

      <section className="panel table-panel">
        <div className="table-meta"><span><strong>{filtered.length.toLocaleString()}</strong> resources</span><span>{selectedKeys.size} selected</span></div>
        {loading ? <TableSkeleton rows={10} /> : !filtered.length ? <EmptyState title="No matching AWS resources" message="Adjust the account, type, or search filters." /> : (
          <>
            <div className="table-scroll">
              <table className="data-table selectable-table">
                <thead><tr><th className="checkbox-column"><input type="checkbox" aria-label="Select visible resources" checked={allVisibleSelected} onChange={(event) => onToggleMany(visible.map((resource) => resource.key), event.target.checked)} /></th><th>Resource</th><th>Private DNS</th><th>Account</th><th>Region</th><th>Status</th></tr></thead>
                <tbody>{visible.map((resource) => (
                  <tr key={resource.key} className={selectedKeys.has(resource.key) ? "is-selected" : ""}>
                    <td className="checkbox-column"><input type="checkbox" aria-label={`Select ${resource.displayName}`} checked={selectedKeys.has(resource.key)} onChange={() => onToggle(resource.key)} /></td>
                    <td><div className="resource-cell"><span className="resource-icon">{resource.kind === "ec2" ? <Server size={16} /> : <Database size={16} />}</span><span><strong>{resource.displayName}</strong><small>{resource.kind.toUpperCase()} · {resource.sourceId}</small></span></div></td>
                    <td><span className="mono-cell endpoint-cell" title={resource.address}>{resource.address}</span></td>
                    <td><div className="stacked-cell"><StatusBadge value={resource.environment} tone={environmentTone(resource.environment)} /><small>{resource.accountId}</small></div></td>
                    <td>{resource.region}</td>
                    <td><StatusBadge value={resource.status} tone={resource.status === "running" || resource.status === "available" ? "success" : "neutral"} /></td>
                  </tr>
                ))}</tbody>
              </table>
            </div>
            <Pagination page={currentPage} pages={pages} onChange={setPage} />
          </>
        )}
      </section>
    </div>
  );
}

export function MongoView({ connections, loading, error, selectedKeys, onToggle, onToggleMany, onOpenBulk }: {
  connections: MongoConnection[];
  loading: boolean;
  error?: string;
  selectedKeys: Set<string>;
  onToggle: (key: string) => void;
  onToggleMany: (keys: string[], checked: boolean) => void;
  onOpenBulk: () => void;
}) {
  const [environment, setEnvironment] = useState<"all" | ResourceEnvironment>("all");
  const [query, setQuery] = useState("");
  const [page, setPage] = useState(0);
  const [copied, setCopied] = useState<string>();
  const filtered = useMemo(() => {
    const search = query.trim().toLocaleLowerCase();
    return connections.filter((connection) =>
      (environment === "all" || connection.environment === environment) &&
      (!search || [connection.cluster, connection.projectId, connection.connectionType, connection.domain].some((value) => value.toLocaleLowerCase().includes(search))),
    );
  }, [connections, environment, query]);
  const pages = Math.max(1, Math.ceil(filtered.length / PAGE_SIZE));
  const currentPage = Math.min(page, pages - 1);
  const visible = filtered.slice(currentPage * PAGE_SIZE, (currentPage + 1) * PAGE_SIZE);
  const allVisibleSelected = visible.length > 0 && visible.every((connection) => selectedKeys.has(connection.key));
  const allFilteredSelected = filtered.length > 0 && filtered.every((connection) => selectedKeys.has(connection.key));

  async function copy(connection: MongoConnection) {
    await navigator.clipboard.writeText(connection.domain);
    setCopied(connection.key);
    window.setTimeout(() => setCopied(undefined), 1600);
  }

  if (error) return <ErrorState title="MongoDB inventory unavailable" message={error} />;

  return (
    <div className="view-stack">
      <section className="toolbar-panel mongo-toolbar">
        <div className="segmented-control" aria-label="MongoDB environment filter">
          {(["all", "production", "staging", "unclassified"] as const).map((value) => <button key={value} className={environment === value ? "is-active" : ""} onClick={() => { setEnvironment(value); setPage(0); }}>{value}</button>)}
        </div>
        <label className="search-field"><Search size={16} /><span className="sr-only">Search MongoDB domains</span><input value={query} onChange={(event) => { setQuery(event.target.value); setPage(0); }} placeholder="Search cluster, project, domain" /></label>
        <button className="button button-secondary" onClick={() => onToggleMany(filtered.map((connection) => connection.key), !allFilteredSelected)} disabled={!filtered.length || (!allFilteredSelected && selectedKeys.size >= 1000)}><Check size={16} /> {allFilteredSelected ? "Clear filtered" : "Select filtered"}</button>
        <button className="button button-primary" onClick={onOpenBulk} disabled={!selectedKeys.size}><Plus size={16} /> Add selected <span className="button-count">{selectedKeys.size}</span></button>
      </section>
      <section className="panel table-panel">
        <div className="table-meta"><span><strong>{filtered.length.toLocaleString()}</strong> normalized domains across {new Set(filtered.map((item) => item.cluster)).size} clusters</span><span>{selectedKeys.size} selected</span></div>
        {loading ? <TableSkeleton rows={10} /> : !filtered.length ? <EmptyState title="No MongoDB domains" message="No normalized Atlas domains matched the current filters." /> : (
          <>
            <div className="table-scroll">
              <table className="data-table mongo-table selectable-table">
                <thead><tr><th className="checkbox-column"><input type="checkbox" aria-label="Select visible MongoDB domains" checked={allVisibleSelected} onChange={(event) => onToggleMany(visible.map((connection) => connection.key), event.target.checked)} /></th><th>Cluster</th><th>Domain</th><th>Environment</th><th>Source</th><th>State</th><th><span className="sr-only">Actions</span></th></tr></thead>
                <tbody>{visible.map((connection) => (
                  <tr key={connection.key} className={selectedKeys.has(connection.key) ? "is-selected" : ""}>
                    <td className="checkbox-column"><input type="checkbox" aria-label={`Select ${connection.domain}`} checked={selectedKeys.has(connection.key)} onChange={() => onToggle(connection.key)} /></td>
                    <td><div className="stacked-cell"><strong>{connection.cluster}</strong><small>{connection.projectId}</small></div></td>
                    <td><span className="mono-cell endpoint-cell mongo-uri" title={connection.domain}>{connection.domain}</span></td>
                    <td><StatusBadge value={connection.environment} tone={environmentTone(connection.environment)} /></td>
                    <td><StatusBadge value={connection.connectionType.replaceAll(".", " / ")} tone="neutral" /></td>
                    <td><StatusBadge value={connection.state} tone={connection.state === "IDLE" ? "success" : "neutral"} /></td>
                    <td><button className="icon-button" aria-label={`Copy ${connection.domain}`} title="Copy domain" onClick={() => void copy(connection)}>{copied === connection.key ? <Check size={17} /> : <Copy size={17} />}</button></td>
                  </tr>
                ))}</tbody>
              </table>
            </div>
            <Pagination page={currentPage} pages={pages} onChange={setPage} />
          </>
        )}
      </section>
    </div>
  );
}

type NetBirdTab = "networks" | "resources" | "routers" | "peers" | "policies" | "groups" | "users";

async function sendCreateNetwork(body: CreateNetworkRequest): Promise<CreateNetworkResponse> {
  const response = await fetch("/api/netbird/networks", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const payload = (await response.json().catch(() => ({}))) as CreateNetworkResponse & { error?: string };
  if (!response.ok) throw new Error(payload.error || `Network request failed with status ${response.status}.`);
  return payload;
}

async function sendCreateGroup(body: CreateGroupRequest): Promise<CreateGroupResponse> {
  const response = await fetch("/api/netbird/groups", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const payload = (await response.json().catch(() => ({}))) as CreateGroupResponse & { error?: string };
  if (!response.ok) throw new Error(payload.error || `Group request failed with status ${response.status}.`);
  return payload;
}

async function sendCreatePolicy(body: CreatePolicyRequest, policyId?: string): Promise<CreatePolicyResponse> {
  const response = await fetch(policyId ? `/api/netbird/policies/${encodeURIComponent(policyId)}` : "/api/netbird/policies", {
    method: policyId ? "PUT" : "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const payload = (await response.json().catch(() => ({}))) as CreatePolicyResponse & { error?: string };
  if (!response.ok) throw new Error(payload.error || `Policy request failed with status ${response.status}.`);
  return payload;
}

async function sendUpdateRouter(routerId: string, body: UpdateRouterRequest): Promise<UpdateRouterResponse> {
  const response = await fetch(`/api/netbird/routers/${encodeURIComponent(routerId)}`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const payload = (await response.json().catch(() => ({}))) as UpdateRouterResponse & { error?: string };
  if (!response.ok) throw new Error(payload.error || `Router request failed with status ${response.status}.`);
  return payload;
}

type RouterSourceMode = "peer" | "groups";

interface RouterDraft {
  sourceMode: RouterSourceMode;
  peerId: string;
  peerGroupIds: string[];
  metric: number;
  masquerade: boolean;
  enabled: boolean;
}

function routerDraft(router: NetBirdRouter): RouterDraft {
  const peerGroups = router.peer_groups ?? [];
  return {
    sourceMode: router.peer ? "peer" : "groups",
    peerId: router.peer ?? "",
    peerGroupIds: [...peerGroups],
    metric: router.metric ?? 1,
    masquerade: router.masquerade ?? false,
    enabled: router.enabled ?? false,
  };
}

function routerRequest(router: NetBirdRouter, draft: RouterDraft): UpdateRouterRequest {
  if (!router.networkId) throw new Error("This router is not associated with a NetBird network.");
  if (!Number.isInteger(draft.metric) || draft.metric < 1 || draft.metric > 9_999) {
    throw new Error("Router metric must be an integer between 1 and 9999.");
  }
  if (draft.sourceMode === "peer") {
    if (!draft.peerId) throw new Error("Choose one routing peer.");
    return {
      networkId: router.networkId,
      peer: draft.peerId,
      metric: draft.metric,
      masquerade: draft.masquerade,
      enabled: draft.enabled,
    };
  }
  if (!draft.peerGroupIds.length) throw new Error("Choose at least one routing peer group.");
  return {
    networkId: router.networkId,
    peer_groups: [...new Set(draft.peerGroupIds)],
    metric: draft.metric,
    masquerade: draft.masquerade,
    enabled: draft.enabled,
  };
}

function RouterEditorModal({ snapshot, router, onClose, onSaved }: {
  snapshot: NetBirdSnapshot;
  router: NetBirdRouter;
  onClose: () => void;
  onSaved: () => Promise<void>;
}) {
  const [draft, setDraft] = useState(() => routerDraft(router));
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string>();

  async function save() {
    setSaving(true);
    setError(undefined);
    try {
      await sendUpdateRouter(router.id, routerRequest(router, draft));
      await onSaved();
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Router update failed.");
    } finally {
      setSaving(false);
    }
  }

  const currentPeerMissing = Boolean(draft.peerId && !snapshot.peers.some((peer) => peer.id === draft.peerId));
  const currentGroups = new Set(snapshot.groups.map((group) => group.id));
  const missingGroups = draft.peerGroupIds.filter((groupId) => !currentGroups.has(groupId));

  return (
    <div className="modal-backdrop" role="presentation" onMouseDown={(event) => { if (!saving && event.currentTarget === event.target) onClose(); }}>
      <form className="modal router-modal" role="dialog" aria-modal="true" aria-labelledby="router-editor-title" onSubmit={(event) => { event.preventDefault(); void save(); }}>
        <button type="button" className="icon-button modal-close" aria-label="Close router editor" onClick={onClose} disabled={saving}><X size={18} /></button>
        <div className="modal-icon"><Router size={22} /></div>
        <h2 id="router-editor-title">Edit NetBird router</h2>
        <p className="modal-subtitle">{router.networkName || router.networkId}</p>
        <div className="policy-form-grid router-form-grid">
          <label className="field"><span>Metric</span><input type="number" min="1" max="9999" required value={draft.metric} onChange={(event) => setDraft((current) => ({ ...current, metric: Number(event.target.value) }))} /></label>
          <div className="policy-toggles"><label className="policy-toggle"><input type="checkbox" checked={draft.masquerade} onChange={(event) => setDraft((current) => ({ ...current, masquerade: event.target.checked }))} /><span>Masquerade traffic</span></label><label className="policy-toggle"><input type="checkbox" checked={draft.enabled} onChange={(event) => setDraft((current) => ({ ...current, enabled: event.target.checked }))} /><span>Enable router</span></label></div>
        </div>
        <fieldset className="endpoint-selector router-source-selector">
          <legend>Route source</legend>
          <div className="segmented-control compact-segmented" aria-label="Router source type">
            <button type="button" className={draft.sourceMode === "peer" ? "is-active" : ""} onClick={() => setDraft((current) => ({ ...current, sourceMode: "peer" }))}>Peer</button>
            <button type="button" className={draft.sourceMode === "groups" ? "is-active" : ""} onClick={() => setDraft((current) => ({ ...current, sourceMode: "groups" }))}>Peer groups</button>
          </div>
          {draft.sourceMode === "peer" ? (
            <label className="field"><span>Routing peer</span><select value={draft.peerId} onChange={(event) => setDraft((current) => ({ ...current, peerId: event.target.value }))}><option value="">Choose peer</option>{currentPeerMissing ? <option value={draft.peerId}>Current peer ({draft.peerId})</option> : null}{snapshot.peers.map((peer) => <option key={peer.id} value={peer.id}>{peer.name || peer.hostname || peer.id}</option>)}</select></label>
          ) : (
            <div className="policy-group-options">
              {missingGroups.map((groupId) => <label key={groupId}><input type="checkbox" checked onChange={() => setDraft((current) => ({ ...current, peerGroupIds: current.peerGroupIds.filter((id) => id !== groupId) }))} /><span><strong>Current group ({groupId})</strong><small>Unavailable in the latest snapshot</small></span></label>)}
              {snapshot.groups.map((group) => <label key={group.id}><input type="checkbox" checked={draft.peerGroupIds.includes(group.id)} onChange={() => setDraft((current) => ({ ...current, peerGroupIds: toggleId(current.peerGroupIds, group.id) }))} /><span><strong>{group.name}</strong><small>{group.peers_count ?? group.peers?.length ?? 0} peers</small></span></label>)}
            </div>
          )}
        </fieldset>
        {error ? <div className="modal-error" role="alert"><AlertTriangle size={15} /><span>{error}</span></div> : null}
        <div className="modal-actions"><button type="button" className="button button-secondary" onClick={onClose} disabled={saving}>Cancel</button><button type="submit" className="button button-primary" disabled={saving}>{saving ? "Saving..." : "Save router"}</button></div>
      </form>
    </div>
  );
}

type PolicyEndpointMode = "groups" | "resource";

interface PolicyRuleDraft {
  id?: string;
  name: string;
  description: string;
  enabled: boolean;
  action: NetBirdPolicyAction;
  bidirectional: boolean;
  protocol: NetBirdPolicyProtocol;
  ports: string;
  sourceMode: PolicyEndpointMode;
  sourceGroupIds: string[];
  sourceResourceId: string;
  sourceResourceType?: NetBirdResourceType;
  destinationMode: PolicyEndpointMode;
  destinationGroupIds: string[];
  destinationResourceId: string;
  destinationResourceType?: NetBirdResourceType;
  authorizedGroups?: Record<string, string[]>;
}

interface PolicyDraft {
  name: string;
  description: string;
  enabled: boolean;
  sourcePostureChecks: string[];
  rules: PolicyRuleDraft[];
}

const policyProtocols: NetBirdPolicyProtocol[] = ["all", "tcp", "udp", "icmp", "netbird-ssh"];
const policyActions: NetBirdPolicyAction[] = ["accept", "drop"];

function policyProtocol(value: string | undefined): NetBirdPolicyProtocol {
  return policyProtocols.includes(value as NetBirdPolicyProtocol) ? value as NetBirdPolicyProtocol : "tcp";
}

function policyAction(value: string | undefined): NetBirdPolicyAction {
  return policyActions.includes(value as NetBirdPolicyAction) ? value as NetBirdPolicyAction : "accept";
}

function portText(rule: NetBirdPolicyRule): string {
  return [
    ...(rule.ports ?? []),
    ...(rule.port_ranges ?? []).map((range) => range.start === range.end ? String(range.start) : `${range.start}-${range.end}`),
  ].join(", ");
}

function emptyPolicyRule(index = 1): PolicyRuleDraft {
  return {
    name: `Rule ${index}`,
    description: "",
    enabled: false,
    action: "accept",
    bidirectional: false,
    protocol: "tcp",
    ports: "",
    sourceMode: "groups",
    sourceGroupIds: [],
    sourceResourceId: "",
    destinationMode: "groups",
    destinationGroupIds: [],
    destinationResourceId: "",
  };
}

function policyRuleDraft(rule: NetBirdPolicyRule, index: number): PolicyRuleDraft {
  const sourceResourceId = rule.sourceResource?.id ?? "";
  const destinationResourceId = rule.destinationResource?.id ?? "";
  return {
    id: rule.id,
    name: rule.name || `Rule ${index + 1}`,
    description: rule.description || "",
    enabled: rule.enabled ?? false,
    action: policyAction(rule.action),
    bidirectional: rule.bidirectional ?? false,
    protocol: policyProtocol(rule.protocol),
    ports: portText(rule),
    sourceMode: sourceResourceId ? "resource" : "groups",
    sourceGroupIds: rule.sources?.map((group) => group.id) ?? [],
    sourceResourceId,
    sourceResourceType: rule.sourceResource?.type,
    destinationMode: destinationResourceId ? "resource" : "groups",
    destinationGroupIds: rule.destinations?.map((group) => group.id) ?? [],
    destinationResourceId,
    destinationResourceType: rule.destinationResource?.type,
    authorizedGroups: rule.authorized_groups ? Object.fromEntries(
      Object.entries(rule.authorized_groups).map(([groupId, users]) => [groupId, [...users]]),
    ) : undefined,
  };
}

function policyDraft(policy?: NetBirdPolicy): PolicyDraft {
  if (!policy) {
    return { name: "", description: "", enabled: false, sourcePostureChecks: [], rules: [emptyPolicyRule()] };
  }
  return {
    name: policy.name,
    description: policy.description || "",
    enabled: policy.enabled ?? false,
    sourcePostureChecks: [...(policy.source_posture_checks ?? [])],
    rules: policy.rules?.length ? policy.rules.map(policyRuleDraft) : [emptyPolicyRule()],
  };
}

function toggleId(ids: string[], id: string): string[] {
  return ids.includes(id) ? ids.filter((item) => item !== id) : [...ids, id];
}

function resourceReference(resourceId: string, resourceType: NetBirdResourceType | undefined, resources: NetBirdResource[], label: string) {
  const resource = resources.find((item) => item.id === resourceId);
  if (resource?.type) return { id: resource.id, type: resource.type };
  if (resourceId && resourceType) return { id: resourceId, type: resourceType };
  throw new Error(`${label} must be an existing NetBird resource.`);
}

function endpointInput(rule: PolicyRuleDraft, side: "source" | "destination", resources: NetBirdResource[]): Pick<NetBirdPolicyRuleInput, "sources" | "sourceResource" | "destinations" | "destinationResource"> {
  const isSource = side === "source";
  const mode = isSource ? rule.sourceMode : rule.destinationMode;
  const groupIds = isSource ? rule.sourceGroupIds : rule.destinationGroupIds;
  const selectedResourceId = isSource ? rule.sourceResourceId : rule.destinationResourceId;
  const selectedResourceType = isSource ? rule.sourceResourceType : rule.destinationResourceType;
  const label = isSource ? "Source" : "Destination";
  if (mode === "groups") {
    if (!groupIds.length) throw new Error(`${label} requires at least one group.`);
    return isSource ? { sources: [...new Set(groupIds)] } : { destinations: [...new Set(groupIds)] };
  }
  const selectedResource = resourceReference(selectedResourceId, selectedResourceType, resources, label);
  return isSource ? { sourceResource: selectedResource } : { destinationResource: selectedResource };
}

function policyRequest(draft: PolicyDraft, resources: NetBirdResource[]): CreatePolicyRequest {
  const rules = draft.rules.map((rule) => {
    if (rule.ports.trim() && rule.protocol !== "tcp" && rule.protocol !== "udp") {
      throw new Error(`Ports are only supported for TCP or UDP in ${rule.name || "this rule"}.`);
    }
    const input: NetBirdPolicyRuleInput = {
      ...(rule.id ? { id: rule.id } : {}),
      name: rule.name,
      description: rule.description,
      enabled: rule.enabled,
      action: rule.action,
      bidirectional: rule.bidirectional,
      protocol: rule.protocol,
      ...(rule.ports.trim() ? parsePortInput(rule.ports) : {}),
      ...(rule.authorizedGroups ? { authorized_groups: rule.authorizedGroups } : {}),
      ...endpointInput(rule, "source", resources),
      ...endpointInput(rule, "destination", resources),
    };
    return input;
  });
  return {
    name: draft.name,
    description: draft.description,
    enabled: draft.enabled,
    source_posture_checks: draft.sourcePostureChecks,
    rules,
  };
}

function PolicyEndpointSelector({
  label,
  mode,
  groupIds,
  resourceId,
  resourceType,
  groups,
  resources,
  onModeChange,
  onToggleGroup,
  onResourceChange,
}: {
  label: string;
  mode: PolicyEndpointMode;
  groupIds: string[];
  resourceId: string;
  resourceType?: NetBirdResourceType;
  groups: NetBirdGroup[];
  resources: NetBirdResource[];
  onModeChange: (mode: PolicyEndpointMode) => void;
  onToggleGroup: (id: string) => void;
  onResourceChange: (id: string) => void;
}) {
  return (
    <fieldset className="endpoint-selector">
      <legend>{label}</legend>
      <div className="segmented-control compact-segmented" aria-label={`${label} selector type`}>
        <button type="button" className={mode === "groups" ? "is-active" : ""} onClick={() => onModeChange("groups")}>Groups</button>
        <button type="button" className={mode === "resource" ? "is-active" : ""} onClick={() => onModeChange("resource")}>Resource</button>
      </div>
      {mode === "groups" ? (
        <div className="policy-group-options">
          {groups.map((group) => <label key={group.id}><input type="checkbox" checked={groupIds.includes(group.id)} onChange={() => onToggleGroup(group.id)} /><span><strong>{group.name}</strong><small>{group.peers_count ?? group.peers?.length ?? 0} peers</small></span></label>)}
        </div>
      ) : (
        <label className="field"><span>{label} resource</span><select value={resourceId} onChange={(event) => onResourceChange(event.target.value)}><option value="">Choose resource</option>{resourceId && !resources.some((resource) => resource.id === resourceId) ? <option value={resourceId}>Current {resourceType || "resource"} ({resourceId})</option> : null}{resources.filter((resource) => resource.type).map((resource) => <option key={resource.id} value={resource.id}>{resource.name} ({resource.networkName})</option>)}</select></label>
      )}
    </fieldset>
  );
}

function PolicyEditorModal({ snapshot, policy, onClose, onSaved }: {
  snapshot: NetBirdSnapshot;
  policy?: NetBirdPolicy;
  onClose: () => void;
  onSaved: () => Promise<void>;
}) {
  const [draft, setDraft] = useState(() => policyDraft(policy));
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string>();

  function updateRule(index: number, update: (rule: PolicyRuleDraft) => PolicyRuleDraft) {
    setDraft((current) => ({ ...current, rules: current.rules.map((rule, ruleIndex) => ruleIndex === index ? update(rule) : rule) }));
  }

  async function save() {
    setSaving(true);
    setError(undefined);
    try {
      await sendCreatePolicy(policyRequest(draft, snapshot.resources), policy?.id);
      await onSaved();
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Policy request failed.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="modal-backdrop" role="presentation" onMouseDown={(event) => { if (!saving && event.currentTarget === event.target) onClose(); }}>
      <form className="modal policy-modal" role="dialog" aria-modal="true" aria-labelledby="policy-editor-title" onSubmit={(event) => { event.preventDefault(); void save(); }}>
        <button type="button" className="icon-button modal-close" aria-label="Close policy editor" onClick={onClose} disabled={saving}><X size={18} /></button>
        <div className="modal-icon"><ShieldCheck size={22} /></div>
        <h2 id="policy-editor-title">{policy ? "Edit NetBird policy" : "Create NetBird policy"}</h2>
        <div className="policy-form-grid">
          <label className="field"><span>Policy name</span><input autoFocus required maxLength={240} value={draft.name} onChange={(event) => setDraft((current) => ({ ...current, name: event.target.value }))} /></label>
          <label className="field policy-description"><span>Description</span><textarea maxLength={1000} value={draft.description} onChange={(event) => setDraft((current) => ({ ...current, description: event.target.value }))} /></label>
          <label className="policy-toggle"><input type="checkbox" checked={draft.enabled} onChange={(event) => setDraft((current) => ({ ...current, enabled: event.target.checked }))} /><span><strong>Enable policy</strong></span></label>
        </div>

        <div className="policy-rule-list">
          {draft.rules.map((rule, index) => (
            <section className="policy-rule-editor" key={rule.id || `new-${index}`}>
              <div className="policy-rule-header"><h3>Rule {index + 1}</h3>{draft.rules.length > 1 ? <button type="button" className="icon-button" aria-label={`Remove rule ${index + 1}`} title="Remove rule" onClick={() => setDraft((current) => ({ ...current, rules: current.rules.filter((_, ruleIndex) => ruleIndex !== index) }))}><Trash2 size={16} /></button> : null}</div>
              <div className="policy-rule-grid">
                <label className="field"><span>Rule name</span><input required maxLength={240} value={rule.name} onChange={(event) => updateRule(index, (current) => ({ ...current, name: event.target.value }))} /></label>
                <label className="field"><span>Rule description</span><input maxLength={1000} value={rule.description} onChange={(event) => updateRule(index, (current) => ({ ...current, description: event.target.value }))} /></label>
                <label className="field"><span>Action</span><select value={rule.action} onChange={(event) => updateRule(index, (current) => ({ ...current, action: event.target.value as NetBirdPolicyAction }))}>{policyActions.map((action) => <option key={action} value={action}>{action}</option>)}</select></label>
                <label className="field"><span>Protocol</span><select value={rule.protocol} onChange={(event) => updateRule(index, (current) => ({ ...current, protocol: event.target.value as NetBirdPolicyProtocol }))}>{policyProtocols.map((protocol) => <option key={protocol} value={protocol}>{protocol}</option>)}</select></label>
                {rule.protocol === "tcp" || rule.protocol === "udp" ? <label className="field"><span>Ports and ranges</span><input value={rule.ports} onChange={(event) => updateRule(index, (current) => ({ ...current, ports: event.target.value }))} placeholder="80, 443, 1000-2000" /></label> : null}
                <div className="policy-toggles"><label className="policy-toggle"><input type="checkbox" checked={rule.enabled} onChange={(event) => updateRule(index, (current) => ({ ...current, enabled: event.target.checked }))} /><span>Enable rule</span></label><label className="policy-toggle"><input type="checkbox" checked={rule.bidirectional} onChange={(event) => updateRule(index, (current) => ({ ...current, bidirectional: event.target.checked }))} /><span>Bidirectional</span></label></div>
              </div>
              <div className="policy-endpoints">
                <PolicyEndpointSelector label="Source" mode={rule.sourceMode} groupIds={rule.sourceGroupIds} resourceId={rule.sourceResourceId} resourceType={rule.sourceResourceType} groups={snapshot.groups} resources={snapshot.resources} onModeChange={(mode) => updateRule(index, (current) => ({ ...current, sourceMode: mode }))} onToggleGroup={(groupId) => updateRule(index, (current) => ({ ...current, sourceGroupIds: toggleId(current.sourceGroupIds, groupId) }))} onResourceChange={(resourceId) => updateRule(index, (current) => ({ ...current, sourceResourceId: resourceId }))} />
                <PolicyEndpointSelector label="Destination" mode={rule.destinationMode} groupIds={rule.destinationGroupIds} resourceId={rule.destinationResourceId} resourceType={rule.destinationResourceType} groups={snapshot.groups} resources={snapshot.resources} onModeChange={(mode) => updateRule(index, (current) => ({ ...current, destinationMode: mode }))} onToggleGroup={(groupId) => updateRule(index, (current) => ({ ...current, destinationGroupIds: toggleId(current.destinationGroupIds, groupId) }))} onResourceChange={(resourceId) => updateRule(index, (current) => ({ ...current, destinationResourceId: resourceId }))} />
              </div>
            </section>
          ))}
        </div>
        <button type="button" className="button button-secondary policy-add-rule" onClick={() => setDraft((current) => ({ ...current, rules: [...current.rules, emptyPolicyRule(current.rules.length + 1)] }))}><Plus size={16} /> Add rule</button>
        {error ? <div className="modal-error" role="alert"><AlertTriangle size={15} /><span>{error}</span></div> : null}
        <div className="modal-actions"><button type="button" className="button button-secondary" onClick={onClose} disabled={saving}>Cancel</button><button type="submit" className="button button-primary" disabled={saving || !draft.name.trim()}>{saving ? "Saving..." : policy ? "Save policy" : "Create policy"}</button></div>
      </form>
    </div>
  );
}

function userGroups(
  user: NetBirdUser,
  devices: NetBirdPeer[],
  groups: NetBirdGroup[],
): NetBirdGroup[] {
  const byId = new Map(groups.map((group) => [group.id, group]));
  const ids = new Set<string>();
  user.auto_groups?.forEach((id) => ids.add(id));
  devices.forEach((peer) => peer.groups?.forEach((group) => ids.add(group.id)));
  return [...ids].map((id) => byId.get(id)).filter((group): group is NetBirdGroup => Boolean(group));
}

function csvCell(value: string | number | undefined): string {
  const text = value === undefined ? "" : String(value);
  return /[",\n]/.test(text) ? `"${text.replace(/"/g, "\"\"")}"` : text;
}

function toCsv(rows: Array<Array<string | number | undefined>>): string {
  return rows.map((row) => row.map(csvCell).join(",")).join("\n");
}

export function NetBirdView({ snapshot, loading, error, onOpenBulk, onNetBirdChanged }: {
  snapshot?: NetBirdSnapshot;
  loading: boolean;
  error?: string;
  onOpenBulk: () => void;
  onNetBirdChanged: () => Promise<void>;
}) {
  const [tab, setTab] = useState<NetBirdTab>("networks");
  const [createOpen, setCreateOpen] = useState(false);
  const [networkName, setNetworkName] = useState("");
  const [networkDescription, setNetworkDescription] = useState("");
  const [createError, setCreateError] = useState<string>();
  const [creating, setCreating] = useState(false);
  const [groupOpen, setGroupOpen] = useState(false);
  const [groupName, setGroupName] = useState("");
  const [groupError, setGroupError] = useState<string>();
  const [creatingGroup, setCreatingGroup] = useState(false);
  const [routerEditor, setRouterEditor] = useState<NetBirdRouter>();
  const [policyEditor, setPolicyEditor] = useState<NetBirdPolicy | "new">();
  const [usersCopied, setUsersCopied] = useState(false);

  function usersCsvRows(): Array<Array<string | number | undefined>> {
    const header = ["User", "Email", "Role", "Status", "Devices", "Connected", "Groups"];
    const body = (snapshot?.users ?? []).map((user) => {
      const devices = snapshot?.peers.filter((peer) => peer.user_id === user.id) ?? [];
      return [
        user.name,
        user.email,
        user.role,
        user.status,
        devices.map((peer) => peer.name).join("; "),
        devices.filter((peer) => peer.connected).length,
        userGroups(user, devices, snapshot?.groups ?? []).map((group) => group.name).join("; "),
      ];
    });
    return [header, ...body];
  }

  function exportUsersCsv() {
    const blob = new Blob([toCsv(usersCsvRows())], { type: "text/csv;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = `netbird-users-${new Date().toISOString().slice(0, 10)}.csv`;
    link.click();
    URL.revokeObjectURL(url);
  }

  async function copyUsersCsv() {
    await navigator.clipboard.writeText(toCsv(usersCsvRows()));
    setUsersCopied(true);
    window.setTimeout(() => setUsersCopied(false), 1600);
  }

  const tabs: Array<{ id: NetBirdTab; label: string; count: number }> = [
    { id: "networks", label: "Networks", count: snapshot?.networks.length ?? 0 },
    { id: "resources", label: "Resources", count: snapshot?.resources.length ?? 0 },
    { id: "routers", label: "Routers", count: snapshot?.routers.length ?? 0 },
    { id: "peers", label: "Peers", count: snapshot?.peers.length ?? 0 },
    { id: "policies", label: "Policies", count: snapshot?.policies.length ?? 0 },
    { id: "groups", label: "Groups", count: snapshot?.groups.length ?? 0 },
    { id: "users", label: "Users", count: snapshot?.users.length ?? 0 },
  ];

  async function createNetwork() {
    setCreating(true);
    setCreateError(undefined);
    try {
      await sendCreateNetwork({ name: networkName, description: networkDescription });
      setCreateOpen(false);
      setNetworkName("");
      setNetworkDescription("");
      await onNetBirdChanged();
    } catch (requestError) {
      setCreateError(requestError instanceof Error ? requestError.message : "Network creation failed.");
    } finally {
      setCreating(false);
    }
  }

  async function createGroup() {
    setCreatingGroup(true);
    setGroupError(undefined);
    try {
      await sendCreateGroup({ name: groupName });
      setGroupOpen(false);
      setGroupName("");
      await onNetBirdChanged();
    } catch (requestError) {
      setGroupError(requestError instanceof Error ? requestError.message : "Resource group creation failed.");
    } finally {
      setCreatingGroup(false);
    }
  }

  if (error) return <ErrorState title="NetBird API unavailable" message={error} />;

  return (
    <div className="view-stack">
      <section className="toolbar-panel netbird-toolbar">
        <div className="segmented-control tab-control" role="tablist" aria-label="NetBird views">
          {tabs.map((item) => <button role="tab" aria-selected={tab === item.id} key={item.id} className={tab === item.id ? "is-active" : ""} onClick={() => setTab(item.id)}>{item.label}<span>{item.count}</span></button>)}
        </div>
        <div className="toolbar-actions-inline">
          {snapshot ? <StatusBadge value={`${snapshot.mode} API`} tone={snapshot.mode === "live" ? "success" : "warning"} /> : null}
          {tab === "networks" ? <button className="button button-secondary" onClick={() => { setCreateError(undefined); setCreateOpen(true); }} disabled={!snapshot || snapshot.mode !== "live"}><Plus size={16} /> New network</button> : null}
          {tab === "groups" ? <button className="button button-secondary" onClick={() => { setGroupError(undefined); setGroupOpen(true); }} disabled={!snapshot || snapshot.mode !== "live"}><Plus size={16} /> New group</button> : null}
          {tab === "policies" ? <button className="button button-secondary" onClick={() => setPolicyEditor("new")} disabled={!snapshot || snapshot.mode !== "live"}><Plus size={16} /> New policy</button> : null}
          {tab === "users" ? <><button className="button button-secondary" onClick={exportUsersCsv} disabled={!snapshot || snapshot.users.length === 0}>Export CSV</button><button className="button button-secondary" onClick={() => void copyUsersCsv()} disabled={!snapshot || snapshot.users.length === 0}>{usersCopied ? <Check size={16} /> : <Copy size={16} />} {usersCopied ? "Copied" : "Copy as CSV"}</button></> : null}
          <button className="button button-primary" onClick={onOpenBulk}><Plus size={16} /> Add resources</button>
        </div>
      </section>

      <section className="panel table-panel">
        {loading ? <TableSkeleton rows={10} /> : !snapshot ? <EmptyState title="No NetBird snapshot" message="Configure the API and refresh." /> : (
          <div className="table-scroll">
            {tab === "networks" ? <table className="data-table"><thead><tr><th>Network</th><th>Resources</th><th>Routers</th><th>Policies</th><th>Routing peers</th></tr></thead><tbody>{snapshot.networks.map((network) => <tr key={network.id}><td><div className="resource-cell"><span className="resource-icon"><Network size={16} /></span><span><strong>{network.name}</strong><small>{network.description || network.id}</small></span></div></td><td>{network.resources?.length ?? 0}</td><td>{network.routers?.length ?? 0}</td><td>{network.policies?.length ?? 0}</td><td>{network.routing_peers_count ?? 0}</td></tr>)}</tbody></table> : null}
            {tab === "resources" ? <table className="data-table"><thead><tr><th>Resource</th><th>Address</th><th>Network</th><th>Groups</th><th>Status</th></tr></thead><tbody>{snapshot.resources.map((resource) => <tr key={resource.id}><td><div className="resource-cell"><span className="resource-icon"><Database size={16} /></span><span><strong>{resource.name}</strong><small>{resource.type || "resource"}</small></span></div></td><td><span className="mono-cell endpoint-cell">{resource.address}</span></td><td>{resource.networkName}</td><td>{resource.groups?.map((group) => group.name).join(", ") || "None"}</td><td><StatusBadge value={resource.enabled ? "enabled" : "disabled"} tone={resource.enabled ? "success" : "neutral"} /></td></tr>)}</tbody></table> : null}
            {tab === "routers" ? <table className="data-table"><thead><tr><th>Router</th><th>Network</th><th>Route source</th><th>Metric</th><th>Masquerade</th><th>Status</th><th><span className="sr-only">Actions</span></th></tr></thead><tbody>{snapshot.routers.map((router) => <tr key={router.id}><td><div className="resource-cell"><span className="resource-icon"><Router size={16} /></span><span><strong>{router.id}</strong></span></div></td><td>{router.networkName || "Unassigned"}</td><td>{router.peer || router.peer_groups?.join(", ") || "Unknown"}</td><td>{router.metric ?? "-"}</td><td>{router.masquerade ? "Yes" : "No"}</td><td><StatusBadge value={router.enabled ? "enabled" : "disabled"} tone={router.enabled ? "success" : "neutral"} /></td><td><button className="icon-button" aria-label={`Edit router ${router.id}`} title="Edit router" onClick={() => setRouterEditor(router)} disabled={snapshot.mode !== "live" || !router.networkId}><Pencil size={16} /></button></td></tr>)}</tbody></table> : null}
            {tab === "peers" ? <table className="data-table"><thead><tr><th>Peer</th><th>NetBird IP</th><th>Operating system</th><th>Version</th><th>Status</th></tr></thead><tbody>{snapshot.peers.map((peer) => <tr key={peer.id}><td><div className="resource-cell"><span className="resource-icon"><Server size={16} /></span><span><strong>{peer.name}</strong><small>{peer.hostname || peer.id}</small></span></div></td><td className="mono-cell">{peer.ip || "-"}</td><td>{peer.os || "Unknown"}</td><td>{peer.version || "Unknown"}</td><td><StatusBadge value={peer.connected ? "connected" : "offline"} tone={peer.connected ? "success" : "neutral"} /></td></tr>)}</tbody></table> : null}
            {tab === "policies" ? <table className="data-table"><thead><tr><th>Policy</th><th>Rules</th><th>Protocols</th><th>Actions</th><th>Status</th><th><span className="sr-only">Actions</span></th></tr></thead><tbody>{snapshot.policies.map((policy) => <tr key={policy.id}><td><div className="resource-cell"><span className="resource-icon"><ShieldCheck size={16} /></span><span><strong>{policy.name}</strong><small>{policy.description || policy.id}</small></span></div></td><td>{policy.rules?.length ?? 0}</td><td>{[...new Set(policy.rules?.map((rule) => rule.protocol).filter(Boolean))].join(", ") || "-"}</td><td>{[...new Set(policy.rules?.map((rule) => rule.action).filter(Boolean))].join(", ") || "-"}</td><td><StatusBadge value={policy.enabled ? "enabled" : "disabled"} tone={policy.enabled ? "success" : "neutral"} /></td><td><button className="icon-button" aria-label={`Edit ${policy.name}`} title="Edit policy" onClick={() => setPolicyEditor(policy)} disabled={snapshot.mode !== "live"}><Pencil size={16} /></button></td></tr>)}</tbody></table> : null}
            {tab === "groups" ? <table className="data-table"><thead><tr><th>Group</th><th>Peers</th><th>Resources</th><th>Group ID</th></tr></thead><tbody>{snapshot.groups.map((group) => <tr key={group.id}><td><div className="resource-cell"><span className="resource-icon"><Users size={16} /></span><span><strong>{group.name}</strong></span></div></td><td>{group.peers_count ?? group.peers?.length ?? 0}</td><td>{group.resources_count ?? group.resources?.length ?? 0}</td><td className="mono-cell">{group.id}</td></tr>)}</tbody></table> : null}
            {tab === "users" ? <table className="data-table"><thead><tr><th>User</th><th>Role</th><th>Devices</th><th>Connected</th><th>Groups</th><th>Status</th></tr></thead><tbody>{snapshot.users.map((user) => { const devices = snapshot.peers.filter((peer) => peer.user_id === user.id); return <tr key={user.id}><td><div className="resource-cell"><span className="resource-icon"><Users size={16} /></span><span><strong>{user.name}</strong><small>{user.email || user.id}</small></span></div></td><td>{user.role}</td><td>{devices.map((peer) => <span className="device-cell" key={peer.id}>{peer.name}<small>{peer.os || "Unknown OS"}</small></span>).length ? devices.map((peer) => <span className="device-cell" key={peer.id}>{peer.name}<small>{peer.os || "Unknown OS"}</small></span>) : "—"}</td><td>{devices.filter((peer) => peer.connected).length}</td><td>{userGroups(user, devices, snapshot.groups).map((group) => <span className="device-cell" key={group.id}>{group.name}</span>).length ? userGroups(user, devices, snapshot.groups).map((group) => <span className="device-cell" key={group.id}>{group.name}</span>) : "—"}</td><td><StatusBadge value={user.status} tone={user.status === "active" ? "success" : user.status === "invited" ? "warning" : "neutral"} /></td></tr>; })}</tbody></table> : null}
          </div>
        )}
      </section>

      {createOpen ? (
        <div className="modal-backdrop" role="presentation" onMouseDown={(event) => { if (!creating && event.currentTarget === event.target) setCreateOpen(false); }}>
          <form className="modal" role="dialog" aria-modal="true" aria-labelledby="create-network-title" onSubmit={(event) => { event.preventDefault(); void createNetwork(); }}>
            <button type="button" className="icon-button modal-close" aria-label="Close network form" onClick={() => setCreateOpen(false)} disabled={creating}><X size={18} /></button>
            <div className="modal-icon"><Network size={22} /></div>
            <h2 id="create-network-title">Create NetBird network</h2>
            <div className="modal-form">
              <label className="field"><span>Network name</span><input autoFocus required maxLength={240} value={networkName} onChange={(event) => setNetworkName(event.target.value)} /></label>
              <label className="field"><span>Description</span><textarea maxLength={1000} value={networkDescription} onChange={(event) => setNetworkDescription(event.target.value)} /></label>
            </div>
            {createError ? <div className="modal-error" role="alert"><AlertTriangle size={15} /><span>{createError}</span></div> : null}
            <div className="modal-actions"><button type="button" className="button button-secondary" onClick={() => setCreateOpen(false)} disabled={creating}>Cancel</button><button type="submit" className="button button-primary" disabled={creating || !networkName.trim()}>{creating ? "Creating..." : "Create network"}</button></div>
          </form>
        </div>
      ) : null}

      {groupOpen ? (
        <div className="modal-backdrop" role="presentation" onMouseDown={(event) => { if (!creatingGroup && event.currentTarget === event.target) setGroupOpen(false); }}>
          <form className="modal" role="dialog" aria-modal="true" aria-labelledby="create-group-title" onSubmit={(event) => { event.preventDefault(); void createGroup(); }}>
            <button type="button" className="icon-button modal-close" aria-label="Close resource group form" onClick={() => setGroupOpen(false)} disabled={creatingGroup}><X size={18} /></button>
            <div className="modal-icon"><Users size={22} /></div>
            <h2 id="create-group-title">Create resource group</h2>
            <div className="modal-form">
              <label className="field"><span>Resource group name</span><input autoFocus required maxLength={240} value={groupName} onChange={(event) => setGroupName(event.target.value)} /></label>
            </div>
            {groupError ? <div className="modal-error" role="alert"><AlertTriangle size={15} /><span>{groupError}</span></div> : null}
            <div className="modal-actions"><button type="button" className="button button-secondary" onClick={() => setGroupOpen(false)} disabled={creatingGroup}>Cancel</button><button type="submit" className="button button-primary" disabled={creatingGroup || !groupName.trim()}>{creatingGroup ? "Creating..." : "Create group"}</button></div>
          </form>
        </div>
      ) : null}

      {routerEditor && snapshot ? <RouterEditorModal key={routerEditor.id} snapshot={snapshot} router={routerEditor} onClose={() => setRouterEditor(undefined)} onSaved={async () => { setRouterEditor(undefined); await onNetBirdChanged(); }} /> : null}
      {policyEditor && snapshot ? <PolicyEditorModal key={policyEditor === "new" ? "new" : policyEditor.id} snapshot={snapshot} policy={policyEditor === "new" ? undefined : policyEditor} onClose={() => setPolicyEditor(undefined)} onSaved={async () => { setPolicyEditor(undefined); await onNetBirdChanged(); }} /> : null}
    </div>
  );
}

async function bulkRequest(body: BulkRequest, signal?: AbortSignal): Promise<BulkResponse> {
  const response = await fetch("/api/netbird/bulk", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal,
  });
  const payload = (await response.json().catch(() => ({}))) as BulkResponse & { error?: string };
  if (!response.ok) throw new Error(payload.error || `Bulk request failed with status ${response.status}.`);
  return payload;
}

type BulkRequestBase = Omit<BulkRequest, "dryRun">;

interface BulkResponseState {
  fingerprint: string;
  snapshotVersion: string;
  response: BulkResponse;
}

interface BulkErrorState {
  fingerprint: string;
  message: string;
}

function bulkRequestFingerprint(request: BulkRequestBase): string {
  const resources = request.resources
    .map((resource) => ({
      key: resource.key,
      name: resource.name,
      address: resource.address,
      kind: resource.kind,
      environment: resource.environment,
      accountId: resource.accountId,
      region: resource.region,
    }))
    .sort((left, right) => JSON.stringify(left).localeCompare(JSON.stringify(right)));

  return JSON.stringify({
    networkId: request.networkId,
    groupIds: [...request.groupIds].sort(),
    resources,
  });
}

export function BulkView({ resources, snapshot, loading, error, nameOverrides, onNameChange, onRemove, onClear, onOpenInventory, onRefreshNetBird }: {
  resources: ResourceCandidate[];
  snapshot?: NetBirdSnapshot;
  loading: boolean;
  error?: string;
  nameOverrides: Record<string, string>;
  onNameChange: (key: string, name: string) => void;
  onRemove: (key: string) => void;
  onClear: () => void;
  onOpenInventory: () => void;
  onRefreshNetBird: () => Promise<void>;
}) {
  const [networkId, setNetworkId] = useState("");
  const [groupIds, setGroupIds] = useState<Set<string>>(new Set());
  const [result, setResult] = useState<BulkResponseState>();
  const [requestError, setRequestError] = useState<BulkErrorState>();
  const [running, setRunning] = useState(false);
  const [checkingFingerprint, setCheckingFingerprint] = useState<string>();
  const [confirmOpen, setConfirmOpen] = useState(false);
  const effectiveNetworkId = networkId || snapshot?.networks[0]?.id || "";
  const selectedNetwork = snapshot?.networks.find((network) => network.id === effectiveNetworkId);
  const selectedGroupIds = useMemo(() => [...groupIds].sort(), [groupIds]);

  function invalidatePreview() {
    setResult(undefined);
    setRequestError(undefined);
    setCheckingFingerprint(undefined);
    setConfirmOpen(false);
  }

  function toggleGroup(groupId: string) {
    setGroupIds((current) => {
      const next = new Set(current);
      if (next.has(groupId)) next.delete(groupId);
      else next.add(groupId);
      return next;
    });
    invalidatePreview();
  }

  const requestBase = useMemo<BulkRequestBase>(() => ({
      networkId: effectiveNetworkId,
      groupIds: selectedGroupIds,
      resources: resources.map((resource) => ({
        key: resource.key,
        name: (nameOverrides[resource.key] ?? resource.resourceName).trim(),
        address: resource.address,
        kind: resource.kind,
        environment: resource.environment,
        accountId: resource.accountId,
        region: resource.region,
      })),
    }), [effectiveNetworkId, nameOverrides, resources, selectedGroupIds]);
  const requestFingerprint = useMemo(() => bulkRequestFingerprint(requestBase), [requestBase]);
  const snapshotVersion = snapshot?.generatedAt ?? "";
  const currentResult = result?.fingerprint === requestFingerprint && (
    !result.response.dryRun || result.snapshotVersion === snapshotVersion
  )
    ? result.response
    : undefined;
  const currentRequestError = requestError?.fingerprint === requestFingerprint
    ? requestError.message
    : undefined;

  function body(dryRun: boolean): BulkRequest {
    return { ...requestBase, dryRun };
  }

  async function run(dryRun: boolean) {
    const fingerprint = requestFingerprint;
    const responseSnapshotVersion = snapshotVersion;

    if (!dryRun && (!currentResult?.dryRun || !currentResult.summary.ready)) {
      setConfirmOpen(false);
      return;
    }

    setRunning(true);
    if (dryRun) {
      setCheckingFingerprint(fingerprint);
      setResult(undefined);
      setConfirmOpen(false);
    }
    setRequestError(undefined);
    try {
      const response = await bulkRequest(body(dryRun));
      setResult({ fingerprint, snapshotVersion: responseSnapshotVersion, response });
      if (!dryRun) {
        setConfirmOpen(false);
        if (response.mode === "live" && response.summary.created > 0) {
          try {
            await onRefreshNetBird();
          } catch (refreshFailure) {
            setRequestError({
              fingerprint,
              message: `Resources were created, but the NetBird refresh failed: ${refreshFailure instanceof Error ? refreshFailure.message : "Unknown refresh error."}`,
            });
          }
        }
      }
    } catch (requestFailure) {
      setRequestError({
        fingerprint,
        message: requestFailure instanceof Error ? requestFailure.message : "Bulk request failed.",
      });
      setConfirmOpen(false);
    } finally {
      setRunning(false);
      if (dryRun) setCheckingFingerprint((current) => current === fingerprint ? undefined : current);
    }
  }

  const canPreview = Boolean(requestBase.resources.length && effectiveNetworkId && selectedGroupIds.length && requestBase.resources.every((resource) => resource.name));
  const checking = checkingFingerprint === requestFingerprint;
  const dryRunResult = currentResult?.dryRun ? currentResult : undefined;
  const readyCount = dryRunResult?.summary.ready ?? 0;
  const localTarget = useMemo(
    () => summarizeBulkTarget(snapshot?.resources ?? [], effectiveNetworkId, selectedGroupIds),
    [effectiveNetworkId, selectedGroupIds, snapshot?.resources],
  );
  const target = dryRunResult?.target ?? localTarget;
  const statusTone: Record<BulkResultStatus, "success" | "danger" | "warning" | "neutral" | "info"> = {
    ready: "info", duplicate: "warning", created: "success", failed: "danger", simulated: "info",
  };

  useEffect(() => {
    let cancelled = false;
    const controller = new AbortController();
    if (!canPreview) return () => controller.abort();

    const timer = window.setTimeout(() => {
      setCheckingFingerprint(requestFingerprint);
      void bulkRequest({ ...requestBase, dryRun: true }, controller.signal)
        .then((response) => {
          if (!cancelled) {
            setResult({ fingerprint: requestFingerprint, snapshotVersion, response });
          }
        })
        .catch((requestFailure: unknown) => {
          if (!cancelled && !(requestFailure instanceof DOMException && requestFailure.name === "AbortError")) {
            setRequestError({
              fingerprint: requestFingerprint,
              message: requestFailure instanceof Error ? requestFailure.message : "Duplicate check failed.",
            });
          }
        })
        .finally(() => {
          if (!cancelled) setCheckingFingerprint((current) => current === requestFingerprint ? undefined : current);
        });
    }, 350);

    return () => {
      cancelled = true;
      window.clearTimeout(timer);
      controller.abort();
    };
  }, [canPreview, requestBase, requestFingerprint, snapshotVersion]);

  if (error) return <ErrorState title="NetBird API unavailable" message={error} />;

  return (
    <div className="view-stack bulk-layout">
      <section className="bulk-grid">
        <div className="bulk-main">
          <section className="panel bulk-section">
            <div className="step-heading"><span>1</span><div><h2>Target</h2><p>Choose the network and resource groups for this batch.</p></div></div>
            {loading ? <TableSkeleton rows={3} /> : !snapshot ? <EmptyState title="No NetBird data" message="Refresh the API connection before creating resources." /> : (
              <div className="target-grid">
                <label className="field"><span>Network</span><select value={effectiveNetworkId} onChange={(event) => { setNetworkId(event.target.value); invalidatePreview(); }}>{snapshot.networks.map((network) => <option key={network.id} value={network.id}>{network.name}</option>)}</select><small>{selectedNetwork?.description || "Resources will be created in this network."}</small><small className="field-help"><strong>{target.networkResourceCount}</strong> resources already in this network</small></label>
                <fieldset className="group-field"><legend>Resource groups</legend><div className="group-options">{snapshot.groups.map((group) => <label key={group.id}><input type="checkbox" checked={groupIds.has(group.id)} onChange={() => toggleGroup(group.id)} /><span><strong>{group.name}</strong><small>{group.resources_count ?? group.resources?.length ?? 0} current resources</small></span></label>)}</div>{groupIds.size ? <small className="field-help"><strong>{target.selectedGroupResourceCount}</strong> distinct resources already in the selected groups</small> : <small className="field-error">Select at least one group.</small>}</fieldset>
              </div>
            )}
          </section>

          <section className="panel bulk-section">
            <div className="step-heading"><span>2</span><div><h2>Resources</h2><p>Review DNS addresses and edit the NetBird names when needed.</p></div><button className="text-button danger-text" onClick={() => { onClear(); invalidatePreview(); }} disabled={!resources.length}>Clear all</button></div>
            {!resources.length ? <EmptyState title="No resources selected" message="Select EC2, RDS, or MongoDB domains from inventory first." action={<button className="button button-secondary empty-action" onClick={onOpenInventory}>Open inventory <ArrowRight size={15} /></button>} /> : (
              <div className="bulk-resource-list">{resources.map((resource) => (
                <div className="bulk-resource-row" key={resource.key}>
                  <div className="bulk-resource-kind">{resource.kind === "ec2" ? <Server size={17} /> : <Database size={17} />}</div>
                  <div className="bulk-resource-fields">
                    <label><span>Resource name</span><input value={nameOverrides[resource.key] ?? resource.resourceName} onChange={(event) => { onNameChange(resource.key, event.target.value); invalidatePreview(); }} /></label>
                    <div><span>DNS address</span><code>{resource.address}</code></div>
                  </div>
                  <div className="bulk-resource-meta"><StatusBadge value={resource.environment} tone={environmentTone(resource.environment)} /><small>{resource.region}</small></div>
                  <button className="icon-button" aria-label={`Remove ${resource.displayName}`} title="Remove resource" onClick={() => { onRemove(resource.key); invalidatePreview(); }}><Trash2 size={16} /></button>
                </div>
              ))}</div>
            )}
          </section>

          {currentResult ? (
            <section className="panel bulk-section results-section">
              <div className="step-heading"><span>3</span><div><h2>{currentResult.dryRun ? "Duplicate check" : "Results"}</h2><p>{currentResult.dryRun ? "The backend has checked the current NetBird inventory." : "The batch finished with the results below."}</p></div></div>
              <div className="result-summary">{Object.entries(currentResult.summary).filter(([, count]) => count > 0).map(([status, count]) => <div key={status}><strong>{count}</strong><span>{status}</span></div>)}</div>
              <div className="result-list">{currentResult.results.map((item) => <div key={item.key}><StatusBadge value={item.status} tone={statusTone[item.status]} /><span><strong>{item.name}</strong><small>{item.reason || item.address}</small></span></div>)}</div>
            </section>
          ) : null}
        </div>

        <aside className="panel action-panel">
          <div className="action-panel-icon"><ClipboardCheck size={21} /></div>
          <h2>Batch summary</h2>
          <dl><div><dt>Selected</dt><dd>{resources.length}</dd></div><div><dt>Network</dt><dd>{selectedNetwork?.name || "Not selected"}</dd></div><div><dt>Already in network</dt><dd>{target.networkResourceCount}</dd></div><div><dt>Selected groups</dt><dd>{groupIds.size}</dd></div><div><dt>Already in groups</dt><dd>{target.selectedGroupResourceCount}</dd></div><div><dt>Duplicate check</dt><dd><StatusBadge value={checking ? "checking" : dryRunResult ? "current" : "pending"} tone={checking ? "info" : dryRunResult ? "success" : "neutral"} /></dd></div><div><dt>API mode</dt><dd><StatusBadge value={snapshot?.mode || "unknown"} tone={snapshot?.mode === "live" ? "success" : "warning"} /></dd></div></dl>
          {currentRequestError ? <div className="action-error"><AlertTriangle size={16} /><span>{currentRequestError}</span></div> : null}
          {!dryRunResult ? <button className="button button-primary button-wide" disabled={!canPreview || running || checking} onClick={() => void run(true)}>{checking || running ? "Checking..." : currentRequestError ? "Retry duplicate check" : "Check for duplicates"}</button> : null}
          {dryRunResult ? <><button className="button button-primary button-wide" disabled={!readyCount || running || checking} onClick={() => setConfirmOpen(true)}>{snapshot?.mode === "live" ? `Create ${readyCount} resources` : `Simulate ${readyCount} resources`}</button><button className="button button-secondary button-wide" disabled={running || checking} onClick={() => void run(true)}>Check again</button></> : null}
          <p className="action-footnote">Duplicate checks run after changes and again immediately before creation. NetBird receives one create request per ready resource.</p>
        </aside>
      </section>

      {confirmOpen && dryRunResult && readyCount > 0 ? (
        <div className="modal-backdrop" role="presentation" onMouseDown={(event) => { if (event.currentTarget === event.target) setConfirmOpen(false); }}>
          <div className="modal" role="dialog" aria-modal="true" aria-labelledby="confirm-title">
            <button className="icon-button modal-close" aria-label="Close confirmation" onClick={() => setConfirmOpen(false)}><X size={18} /></button>
            <div className="modal-icon"><ShieldCheck size={23} /></div>
            <h2 id="confirm-title">{snapshot?.mode === "live" ? "Create NetBird resources?" : "Run demo simulation?"}</h2>
            <p>{snapshot?.mode === "live" ? `${readyCount} resources will be created in ${selectedNetwork?.name}. This operation changes the current NetBird network.` : `${readyCount} resources will be simulated. Demo mode never sends a write to NetBird.`}</p>
            <div className="modal-summary"><span>{readyCount} ready</span><span>{groupIds.size} groups</span><span>{target.networkResourceCount} already in network</span></div>
            <div className="modal-actions"><button className="button button-secondary" onClick={() => setConfirmOpen(false)}>Cancel</button><button className="button button-primary" disabled={running} onClick={() => void run(false)}>{running ? "Processing..." : snapshot?.mode === "live" ? "Confirm create" : "Run simulation"}</button></div>
          </div>
        </div>
      ) : null}
    </div>
  );
}
