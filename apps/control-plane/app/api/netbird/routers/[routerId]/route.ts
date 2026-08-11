import { NextResponse } from "next/server";
import { NetBirdApiError, updateNetBirdRouter } from "@/lib/netbird";
import { parseRouterUpdateRequest } from "@/lib/router-validation";

export const dynamic = "force-dynamic";

export async function PUT(
  request: Request,
  context: { params: Promise<{ routerId: string }> },
): Promise<NextResponse> {
  try {
    const contentLength = Number(request.headers.get("content-length") || 0);
    if (contentLength > 100_000) return NextResponse.json({ error: "Request is too large." }, { status: 413 });
    const { routerId } = await context.params;
    if (!routerId.trim()) return NextResponse.json({ error: "Router ID is required." }, { status: 400 });
    const input = parseRouterUpdateRequest(await request.json());
    return NextResponse.json(await updateNetBirdRouter(routerId, input), {
      headers: { "Cache-Control": "no-store" },
    });
  } catch (error) {
    const status = error instanceof NetBirdApiError && error.status >= 400 && error.status < 500
      ? error.status
      : error instanceof NetBirdApiError
        ? 502
        : 400;
    return NextResponse.json(
      {
        error: error instanceof Error ? error.message : "Router update failed.",
        requestId: error instanceof NetBirdApiError ? error.requestId : undefined,
      },
      { status },
    );
  }
}
