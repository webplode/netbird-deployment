import { NextResponse } from "next/server";
import { isNetBirdDemoMode } from "@/lib/netbird";
import { getSteampipePool } from "@/lib/steampipe";

export const dynamic = "force-dynamic";

export async function GET(): Promise<NextResponse> {
  let steampipe: "connected" | "unavailable" = "unavailable";
  try {
    await getSteampipePool().query("select 1");
    steampipe = "connected";
  } catch {
    steampipe = "unavailable";
  }
  return NextResponse.json({
    status: steampipe === "connected" ? "ok" : "degraded",
    steampipe,
    netbird: isNetBirdDemoMode() ? "demo" : "configured",
    checkedAt: new Date().toISOString(),
  });
}
