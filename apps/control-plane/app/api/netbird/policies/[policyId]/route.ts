import { NextResponse } from "next/server";
import { NetBirdApiError, updateNetBirdPolicy } from "@/lib/netbird";
import { parsePolicyRequest } from "@/lib/policy-validation";

export const dynamic = "force-dynamic";

function errorResponse(error: unknown): NextResponse {
  const status = error instanceof NetBirdApiError && error.status >= 400 && error.status < 500
    ? error.status
    : error instanceof NetBirdApiError
      ? 502
      : 400;
  return NextResponse.json(
    {
      error: error instanceof Error ? error.message : "Policy update failed.",
      requestId: error instanceof NetBirdApiError ? error.requestId : undefined,
    },
    { status },
  );
}

export async function PUT(
  request: Request,
  context: { params: Promise<{ policyId: string }> },
): Promise<NextResponse> {
  try {
    const contentLength = Number(request.headers.get("content-length") || 0);
    if (contentLength > 250_000) return NextResponse.json({ error: "Request is too large." }, { status: 413 });
    const { policyId } = await context.params;
    if (!policyId.trim()) return NextResponse.json({ error: "Policy ID is required." }, { status: 400 });
    const input = parsePolicyRequest(await request.json());
    return NextResponse.json(await updateNetBirdPolicy(policyId, input), {
      headers: { "Cache-Control": "no-store" },
    });
  } catch (error) {
    return errorResponse(error);
  }
}
