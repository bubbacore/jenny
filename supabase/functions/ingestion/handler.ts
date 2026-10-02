import type { SupabaseClient } from "@supabase/supabase-js";
import { hasToken } from "./auth.ts";
import { collectionPlan } from "./collection-plan.ts";
import { failure } from "./http.ts";
import { recordReading } from "./record-reading.ts";
import { startReading } from "./start-reading.ts";

export type Context = { database: SupabaseClient; now: Date };

type Operation = (body: unknown, context: Context) => Promise<Response>;

const operations: Record<string, Operation> = {
  "collection-plan": collectionPlan,
  "start-reading": startReading,
  "record-reading": recordReading,
};

export type Options = {
  database: SupabaseClient;
  hermesToken: string | undefined;
  // Lets local tests fix the clock through the x-ingestion-clock header.
  // Never enabled in production.
  clockOverride: boolean;
};

export async function handle(request: Request, options: Options): Promise<Response> {
  if (!options.hermesToken) {
    console.error("INGESTION_HERMES_TOKEN is not set");
    return failure(503, "not_configured", "A ingestão está sem o token do Hermes configurado.");
  }
  if (!(await hasToken(request, options.hermesToken))) {
    return failure(401, "unauthorized", "Token ausente ou inválido.");
  }

  const name = new URL(request.url).pathname.split("/").filter(Boolean).slice(1).join("/");
  const operation = operations[name];
  if (!operation) {
    return failure(404, "unknown_operation", `Operação desconhecida: ${name || "(vazia)"}.`);
  }
  if (request.method !== "POST") {
    return failure(405, "method_not_allowed", "Use POST.");
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return failure(400, "invalid_json", "O corpo da requisição não é um JSON válido.");
  }

  const now = clock(request, options.clockOverride);
  if (!now) {
    return failure(400, "invalid_clock", "O cabeçalho x-ingestion-clock não é uma data válida.");
  }

  try {
    return await operation(body, { database: options.database, now });
  } catch (error) {
    console.error(error);
    return failure(500, "internal_error", "Erro interno da ingestão.");
  }
}

function clock(request: Request, allowed: boolean): Date | null {
  const header = request.headers.get("x-ingestion-clock");
  if (!allowed || header === null) return new Date();
  const date = new Date(header);
  return Number.isNaN(date.getTime()) ? null : date;
}
