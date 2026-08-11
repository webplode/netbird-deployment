"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import {
  Boxes,
  Cloud,
  Database,
  LayoutDashboard,
  Menu,
  Network,
  RefreshCw,
  ShieldCheck,
  X,
} from "lucide-react";
import {
  BulkView,
  InventoryView,
  MongoView,
  NetBirdView,
  OverviewView,
} from "@/components/views";
import type { InventoryResponse, NetBirdSnapshot } from "@/lib/types";

export type ViewId = "overview" | "inventory" | "mongodb" | "netbird" | "bulk";

interface NavItem {
  id: ViewId;
  label: string;
  icon: typeof LayoutDashboard;
}

const navItems: NavItem[] = [
  { id: "overview", label: "Overview", icon: LayoutDashboard },
  { id: "inventory", label: "AWS inventory", icon: Cloud },
  { id: "mongodb", label: "MongoDB", icon: Database },
  { id: "netbird", label: "NetBird", icon: Network },
  { id: "bulk", label: "Bulk resources", icon: Boxes },
];

const viewCopy: Record<ViewId, { title: string; description: string }> = {
  overview: { title: "Overview", description: "Cloud inventory and private network posture" },
  inventory: { title: "AWS inventory", description: "Private EC2 and RDS DNS across every configured account and region" },
  mongodb: { title: "MongoDB domains", description: "Normalized Atlas DNS resources discovered through Steampipe" },
  netbird: { title: "NetBird network", description: "Networks, resources, routers, peers, groups, and policies" },
  bulk: { title: "Bulk resources", description: "Preview and create NetBird domain resources from AWS and MongoDB" },
};

async function requestJson<T>(url: string, init?: RequestInit): Promise<T> {
  const response = await fetch(url, { ...init, cache: "no-store" });
  const body = (await response.json().catch(() => ({}))) as { error?: string } & T;
  if (!response.ok) throw new Error(body.error || `Request failed with status ${response.status}.`);
  return body;
}

function timeLabel(value?: string): string {
  if (!value) return "Not synced";
  return new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit", second: "2-digit" }).format(
    new Date(value),
  );
}

export function ControlPlane() {
  const [activeView, setActiveView] = useState<ViewId>("overview");
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [inventory, setInventory] = useState<InventoryResponse>();
  const [netbird, setNetbird] = useState<NetBirdSnapshot>();
  const [inventoryError, setInventoryError] = useState<string>();
  const [netbirdError, setNetbirdError] = useState<string>();
  const [inventoryLoading, setInventoryLoading] = useState(true);
  const [netbirdLoading, setNetbirdLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [selectedKeys, setSelectedKeys] = useState<Set<string>>(new Set());
  const [nameOverrides, setNameOverrides] = useState<Record<string, string>>({});

  const loadData = useCallback(async (manual = false) => {
    if (manual) setRefreshing(true);
    setInventoryLoading(true);
    setNetbirdLoading(true);
    setInventoryError(undefined);
    setNetbirdError(undefined);

    const [inventoryResult, netbirdResult] = await Promise.allSettled([
      requestJson<InventoryResponse>("/api/inventory"),
      requestJson<NetBirdSnapshot>("/api/netbird"),
    ]);

    if (inventoryResult.status === "fulfilled") setInventory(inventoryResult.value);
    else setInventoryError(inventoryResult.reason instanceof Error ? inventoryResult.reason.message : "Inventory request failed.");
    if (netbirdResult.status === "fulfilled") setNetbird(netbirdResult.value);
    else setNetbirdError(netbirdResult.reason instanceof Error ? netbirdResult.reason.message : "NetBird request failed.");

    setInventoryLoading(false);
    setNetbirdLoading(false);
    setRefreshing(false);
  }, []);

  useEffect(() => {
    const timer = window.setTimeout(() => void loadData(), 0);
    return () => window.clearTimeout(timer);
  }, [loadData]);

  const selectedResources = useMemo(
    () => [...(inventory?.resources ?? []), ...(inventory?.mongoConnections ?? [])]
      .filter((resource) => selectedKeys.has(resource.key)),
    [inventory, selectedKeys],
  );

  const warnings = [...(inventory?.warnings ?? []), ...(netbird?.warnings ?? [])];

  function navigate(view: ViewId) {
    setActiveView(view);
    setSidebarOpen(false);
  }

  function toggleSelection(key: string) {
    setSelectedKeys((current) => {
      const next = new Set(current);
      if (next.has(key)) next.delete(key);
      else if (next.size < 1000) next.add(key);
      return next;
    });
  }

  function toggleMany(keys: string[], checked: boolean) {
    setSelectedKeys((current) => {
      const next = new Set(current);
      if (!checked) keys.forEach((key) => next.delete(key));
      else {
        for (const key of keys) {
          if (next.size >= 1000) break;
          next.add(key);
        }
      }
      return next;
    });
  }

  function removeSelected(key: string) {
    setSelectedKeys((current) => {
      const next = new Set(current);
      next.delete(key);
      return next;
    });
  }

  const currentCopy = viewCopy[activeView];

  return (
    <div className="app-shell">
      <button
        className={`sidebar-scrim ${sidebarOpen ? "is-visible" : ""}`}
        aria-label="Close navigation"
        onClick={() => setSidebarOpen(false)}
      />
      <aside className={`sidebar ${sidebarOpen ? "is-open" : ""}`}>
        <div className="brand-row">
          <span className="brand-mark" aria-hidden="true"><ShieldCheck size={20} strokeWidth={1.8} /></span>
          <span className="brand-copy"><strong>Sleek Network</strong><small>Control plane</small></span>
          <button className="icon-button sidebar-close" onClick={() => setSidebarOpen(false)} aria-label="Close navigation">
            <X size={18} />
          </button>
        </div>

        <nav className="primary-nav" aria-label="Primary navigation">
          {navItems.map((item) => {
            const Icon = item.icon;
            return (
              <button
                key={item.id}
                className={`nav-item ${activeView === item.id ? "is-active" : ""}`}
                onClick={() => navigate(item.id)}
              >
                <Icon size={18} strokeWidth={1.8} />
                <span>{item.label}</span>
                {item.id === "bulk" && selectedKeys.size > 0 ? <span className="nav-count">{selectedKeys.size}</span> : null}
              </button>
            );
          })}
        </nav>

        <div className="sidebar-connections">
          <p>Connections</p>
          <div className="connection-row">
            <span className={`status-dot ${inventoryError ? "is-error" : inventory ? "is-live" : "is-pending"}`} />
            <span><strong>Steampipe</strong><small>{inventoryError ? "Unavailable" : inventory ? "Live inventory" : "Connecting"}</small></span>
          </div>
          <div className="connection-row">
            <span className={`status-dot ${netbirdError ? "is-error" : netbird?.mode === "live" ? "is-live" : "is-demo"}`} />
            <span><strong>NetBird</strong><small>{netbirdError ? "Unavailable" : netbird?.mode === "live" ? "Live API" : "Demo mode"}</small></span>
          </div>
        </div>
      </aside>

      <main className="main-shell">
        <header className="topbar">
          <div className="topbar-title">
            <button className="icon-button mobile-menu" onClick={() => setSidebarOpen(true)} aria-label="Open navigation">
              <Menu size={20} />
            </button>
            <div>
              <h1>{currentCopy.title}</h1>
              <p>{currentCopy.description}</p>
            </div>
          </div>
          <div className="topbar-actions">
            <span className="sync-label">Synced {timeLabel(inventory?.generatedAt ?? netbird?.generatedAt)}</span>
            <button className="button button-secondary" onClick={() => void loadData(true)} disabled={refreshing}>
              <RefreshCw size={16} className={refreshing ? "is-spinning" : ""} />
              Refresh
            </button>
          </div>
        </header>

        {warnings.length ? (
          <div className={`notice-bar ${netbird?.mode === "demo" ? "is-demo" : ""}`} role="status">
            <span>{warnings[0]}</span>
            {warnings.length > 1 ? <span className="notice-count">+{warnings.length - 1} more</span> : null}
          </div>
        ) : null}

        <div className="page-content">
          {activeView === "overview" ? (
            <OverviewView
              inventory={inventory}
              netbird={netbird}
              inventoryLoading={inventoryLoading}
              netbirdLoading={netbirdLoading}
              inventoryError={inventoryError}
              netbirdError={netbirdError}
              onNavigate={navigate}
            />
          ) : null}
          {activeView === "inventory" ? (
            <InventoryView
              resources={inventory?.resources ?? []}
              loading={inventoryLoading}
              error={inventoryError}
              selectedKeys={selectedKeys}
              onToggle={toggleSelection}
              onToggleMany={toggleMany}
              onOpenBulk={() => navigate("bulk")}
            />
          ) : null}
          {activeView === "mongodb" ? (
            <MongoView
              connections={inventory?.mongoConnections ?? []}
              loading={inventoryLoading}
              error={inventoryError}
              selectedKeys={selectedKeys}
              onToggle={toggleSelection}
              onToggleMany={toggleMany}
              onOpenBulk={() => navigate("bulk")}
            />
          ) : null}
          {activeView === "netbird" ? (
            <NetBirdView
              snapshot={netbird}
              loading={netbirdLoading}
              error={netbirdError}
              onOpenBulk={() => navigate("bulk")}
              onNetBirdChanged={() => loadData(true)}
            />
          ) : null}
          {activeView === "bulk" ? (
            <BulkView
              resources={selectedResources}
              snapshot={netbird}
              loading={netbirdLoading}
              error={netbirdError}
              nameOverrides={nameOverrides}
              onNameChange={(key, name) => setNameOverrides((current) => ({ ...current, [key]: name }))}
              onRemove={removeSelected}
              onClear={() => setSelectedKeys(new Set())}
              onOpenInventory={() => navigate("inventory")}
              onRefreshNetBird={() => loadData(true)}
            />
          ) : null}
        </div>
      </main>
    </div>
  );
}
