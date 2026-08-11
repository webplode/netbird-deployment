import { NextResponse } from "next/server";
import { bulkCreateResources, NetBirdApiError } from "@/lib/netbird";
import type { BulkRequest, BulkResourceInput } from "@/lib/types";

const DNS_PATTERN = /^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i;

function isResource(value: unknown): value is BulkResourceInput {
  if (!value || typeof value !== "object") return false;
  const item = value as Record<string, unknown>;
  return (
    typeof item.key === "string" &&
    typeof item.name === "string" &&
    item.name.trim().length > 0 &&
    item.name.trim().length <= 240 &&
    typeof item.address === "string" &&
    DNS_PATTERN.test(item.address.trim().replace(/\.$/, "")) &&
    (item.kind === "ec2" || item.kind === "rds" || item.kind === "mongodb") &&
    (item.environment === "production" || item.environment === "staging" || item.environment === "unclassified") &&
    typeof item.accountId === "string" &&
    typeof item.region === "string"
  );
}

function parseRequest(value: unknown): BulkRequest {
  if (!value || typeof value !== "object") throw new Error("Request body must be a JSON object.");
  const body = value as Record<string, unknown>;
  if (typeof body.networkId !== "string" || !body.networkId.trim()) throw new Error("Choose a target network.");
  if (!Array.isArray(body.groupIds) || !body.groupIds.length || !body.groupIds.every((id) => typeof id === "string" && id)) {
    throw new Error("Choose at least one NetBird resource group.");
  }
  if (!Array.isArray(body.resources) || !body.resources.length) throw new Error("Select at least one resource.");
  if (body.resources.length > 1000) throw new Error("A bulk request can contain at most 1,000 resources.");
  if (!body.resources.every(isResource)) throw new Error("One or more resources has an invalid name or DNS address.");
  if (typeof body.dryRun !== "boolean") throw new Error("dryRun must be a boolean.");

  return {
    networkId: body.networkId,
    groupIds: [...new Set(body.groupIds as string[])],
    resources: body.resources as BulkResourceInput[],
    dryRun: body.dryRun,
  };
}

export async function POST(request: Request): Promise<NextResponse> {
  try {
    const contentLength = Number(request.headers.get("content-length") || 0);
    if (contentLength > 1_000_000) return NextResponse.json({ error: "Request is too large." }, { status: 413 });
    const body = parseRequest(await request.json());
    return NextResponse.json(await bulkCreateResources(body), {
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
        error: error instanceof Error ? error.message : "Bulk request failed.",
        requestId: error instanceof NetBirdApiError ? error.requestId : undefined,
      },
      { status },
    );
  }
}
