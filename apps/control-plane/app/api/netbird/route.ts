import { NextResponse } from "next/server";
import { getNetBirdSnapshot, NetBirdApiError } from "@/lib/netbird";

export const dynamic = "force-dynamic";

export async function GET(): Promise<NextResponse> {
  try {
    return NextResponse.json(await getNetBirdSnapshot(), {
      headers: { "Cache-Control": "no-store" },
    });
  } catch (error) {
    const status = error instanceof NetBirdApiError && error.status < 500 ? error.status : 502;
    return NextResponse.json(
      {
        error: error instanceof Error ? error.message : "NetBird request failed.",
        requestId: error instanceof NetBirdApiError ? error.requestId : undefined,
      },
      { status },
    );
  }
}
