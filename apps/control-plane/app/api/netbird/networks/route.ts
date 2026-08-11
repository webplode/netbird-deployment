import { NextResponse } from "next/server";
import { createNetBirdNetwork, NetBirdApiError } from "@/lib/netbird";
import type { CreateNetworkRequest } from "@/lib/types";

export const dynamic = "force-dynamic";

function parseRequest(value: unknown): CreateNetworkRequest {
  if (!value || typeof value !== "object") throw new Error("Request body must be a JSON object.");
  const body = value as Record<string, unknown>;
  if (typeof body.name !== "string") throw new Error("Network name is required.");
  if (body.description !== undefined && typeof body.description !== "string") {
    throw new Error("Network description must be a string.");
  }

  const name = body.name.replace(/\s+/g, " ").trim();
  const description = (body.description ?? "").trim();
  if (!name) throw new Error("Network name is required.");
  if (name.length > 240) throw new Error("Network name must be 240 characters or fewer.");
  if (description.length > 1_000) throw new Error("Network description must be 1,000 characters or fewer.");
  return { name, description };
}

export async function POST(request: Request): Promise<NextResponse> {
  try {
    const contentLength = Number(request.headers.get("content-length") || 0);
    if (contentLength > 10_000) return NextResponse.json({ error: "Request is too large." }, { status: 413 });
    const input = parseRequest(await request.json());
    return NextResponse.json(await createNetBirdNetwork(input), {
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
        error: error instanceof Error ? error.message : "Network creation failed.",
        requestId: error instanceof NetBirdApiError ? error.requestId : undefined,
      },
      { status },
    );
  }
}
