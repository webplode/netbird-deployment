import { NextResponse } from "next/server";
import { createNetBirdPolicy, NetBirdApiError } from "@/lib/netbird";
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
      error: error instanceof Error ? error.message : "Policy creation failed.",
      requestId: error instanceof NetBirdApiError ? error.requestId : undefined,
    },
    { status },
  );
}

export async function POST(request: Request): Promise<NextResponse> {
  try {
    const contentLength = Number(request.headers.get("content-length") || 0);
    if (contentLength > 250_000) return NextResponse.json({ error: "Request is too large." }, { status: 413 });
    const input = parsePolicyRequest(await request.json());
    return NextResponse.json(await createNetBirdPolicy(input), {
      headers: { "Cache-Control": "no-store" },
    });
  } catch (error) {
    return errorResponse(error);
  }
}
