import { NextResponse } from "next/server";
import { getInventory } from "@/lib/steampipe";

export const dynamic = "force-dynamic";

export async function GET(): Promise<NextResponse> {
  try {
    return NextResponse.json(await getInventory(), {
      headers: { "Cache-Control": "no-store" },
    });
  } catch (error) {
    return NextResponse.json(
      {
        error: error instanceof Error ? error.message : "Inventory request failed.",
        hint: "Confirm that `steampipe service status` reports a local service on port 9193.",
      },
      { status: 503 },
    );
  }
}
