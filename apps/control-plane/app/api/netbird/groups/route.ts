import { NextResponse } from "next/server";
import { createNetBirdGroup, NetBirdApiError } from "@/lib/netbird";
import type { CreateGroupRequest } from "@/lib/types";

export const dynamic = "force-dynamic";

function parseRequest(value: unknown): CreateGroupRequest {
  if (!value || typeof value !== "object") throw new Error("Request body must be a JSON object.");
  const body = value as Record<string, unknown>;
  if (typeof body.name !== "string") throw new Error("Resource group name is required.");

  const name = body.name.replace(/\s+/g, " ").trim();
  if (!name) throw new Error("Resource group name is required.");
  if (name.length > 240) throw new Error("Resource group name must be 240 characters or fewer.");
  return { name };
}

export async function POST(request: Request): Promise<NextResponse> {
  try {
    const contentLength = Number(request.headers.get("content-length") || 0);
    if (contentLength > 10_000) return NextResponse.json({ error: "Request is too large." }, { status: 413 });
    const input = parseRequest(await request.json());
    return NextResponse.json(await createNetBirdGroup(input), {
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
        error: error instanceof Error ? error.message : "Resource group creation failed.",
        requestId: error instanceof NetBirdApiError ? error.requestId : undefined,
      },
      { status },
    );
  }
}
