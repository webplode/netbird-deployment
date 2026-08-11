import "server-only";

import { Pool, type QueryResultRow } from "pg";
import { buildAwsCandidates, buildMongoConnections, type Ec2Row, type MongoRow, type RdsRow } from "@/lib/inventory-utils";
import type { AwsEnvironment, InventoryResponse } from "@/lib/types";

declare global {
  var sleekSteampipePool: Pool | undefined;
}

interface AwsSource {
  environment: AwsEnvironment;
  schema: string;
}

function schemaName(value: string | undefined, fallback: string): string {
  const schema = value?.trim() || fallback;
  if (!/^[a-z_][a-z0-9_]*$/i.test(schema)) {
    throw new Error(`Invalid Steampipe schema name: ${schema}`);
  }
  return schema;
}

const awsSources: AwsSource[] = [
  { environment: "staging", schema: schemaName(process.env.STEAMPIPE_STAGING_SCHEMA, "aws_staging") },
  { environment: "production", schema: schemaName(process.env.STEAMPIPE_PRODUCTION_SCHEMA, "aws_production") },
];

const mongoSchema = schemaName(process.env.STEAMPIPE_MONGODB_SCHEMA, "mongodbatlas");

function quotedIdentifier(value: string): string {
  return `"${value.replaceAll('"', '""')}"`;
}

export function getSteampipePool(): Pool {
  if (globalThis.sleekSteampipePool) return globalThis.sleekSteampipePool;

  const pool = new Pool({
    connectionString: process.env.STEAMPIPE_DATABASE_URL ?? "postgres://steampipe@127.0.0.1:9193/steampipe",
    application_name: "sleek-netbird-control-plane",
    connectionTimeoutMillis: 5_000,
    idleTimeoutMillis: 30_000,
    max: 6,
    query_timeout: 180_000,
  });

  pool.on("error", (error) => console.error("Steampipe idle connection error", error.message));
  globalThis.sleekSteampipePool = pool;
  return pool;
}

async function queryRows<T extends QueryResultRow>(sql: string): Promise<T[]> {
  const result = await getSteampipePool().query<T>(sql);
  return result.rows;
}

async function loadAwsSource(source: AwsSource): Promise<{ ec2: Ec2Row[]; rds: RdsRow[] }> {
  const schema = quotedIdentifier(source.schema);
  const [ec2, rds] = await Promise.all([
    queryRows<Ec2Row>(`
      select account_id, region, instance_id, coalesce(tags ->> 'Name', '') as instance_name,
             private_dns_name, instance_state, instance_type, sp_connection_name
      from ${schema}.aws_ec2_instance
      where nullif(private_dns_name, '') is not null
    `),
    queryRows<RdsRow>(`
      select account_id, region, db_instance_identifier, endpoint_address, engine, status,
             sp_connection_name
      from ${schema}.aws_rds_db_instance
      where nullif(endpoint_address, '') is not null
    `),
  ]);
  return { ec2, rds };
}

async function loadMongo(): Promise<MongoRow[]> {
  return queryRows<MongoRow>(`
    select name, project_id, state_name, mongo_uri, mongo_uri_with_options, srv_address,
           connection_strings
    from ${quotedIdentifier(mongoSchema)}.mongodbatlas_cluster
    order by name
  `);
}

export async function getInventory(): Promise<InventoryResponse> {
  const warnings: string[] = [];
  const ec2ByEnvironment: Array<{ environment: AwsEnvironment; rows: Ec2Row[]; schema: string }> = [];
  const rdsByEnvironment: Array<{ environment: AwsEnvironment; rows: RdsRow[]; schema: string }> = [];

  const [awsSettled, mongoSettled] = await Promise.all([
    Promise.allSettled(awsSources.map((source) => loadAwsSource(source))),
    Promise.allSettled([loadMongo()]),
  ]);

  awsSettled.forEach((result, index) => {
    const source = awsSources[index];
    if (result.status === "fulfilled") {
      ec2ByEnvironment.push({ environment: source.environment, rows: result.value.ec2, schema: source.schema });
      rdsByEnvironment.push({ environment: source.environment, rows: result.value.rds, schema: source.schema });
    } else {
      warnings.push(`${source.environment} AWS inventory failed: ${result.reason instanceof Error ? result.reason.message : "Unknown error"}`);
    }
  });

  let mongoRows: MongoRow[] = [];
  const mongoResult = mongoSettled[0];
  if (mongoResult.status === "fulfilled") mongoRows = mongoResult.value;
  else warnings.push(`MongoDB Atlas inventory failed: ${mongoResult.reason instanceof Error ? mongoResult.reason.message : "Unknown error"}`);

  if (!ec2ByEnvironment.length && !rdsByEnvironment.length && !mongoRows.length) {
    throw new Error(warnings.join(" ") || "Steampipe returned no inventory sources.");
  }

  return {
    mode: "live",
    generatedAt: new Date().toISOString(),
    resources: buildAwsCandidates(ec2ByEnvironment, rdsByEnvironment),
    mongoConnections: buildMongoConnections(mongoRows, mongoSchema),
    warnings,
  };
}
