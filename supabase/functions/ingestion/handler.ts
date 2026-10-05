import type { SupabaseClient } from "@supabase/supabase-js";
import { hasToken } from "./auth.ts";
import { collectionPlan } from "./collection-plan.ts";
import { collectionSummary } from "./collection-summary.ts";
import { dailyCollectionStatus } from "./daily-collection-status.ts";
import { finishCollection } from "./finish-collection.ts";
import { failure } from "./http.ts";
import { recollectionCinemas } from "./recollection-cinemas.ts";
import { recordImage } from "./record-image.ts";
import { recordReading } from "./record-reading.ts";
import { resolvePendingIdentification } from "./resolve-pending-identification.ts";
import { recordSitePublication, recordSiteReversion } from "./site-publication.ts";
import { startReading } from "./start-reading.ts";

export type Context = { database: SupabaseClient; now: Date };

type Operation = (body: unknown, context: Context) => Promise<Response>;

// Who may call an operation: the Hermes, or the collection watchman, whose
// token reaches only the daily collection status.
type Caller = "hermes" | "watchman";

const operations: Record<string, { caller: Caller; run: Operation }> = {
  "collection-plan": { caller: "hermes", run: collectionPlan },
  "start-reading": { caller: "hermes", run: startReading },
  "record-image": { caller: "hermes", run: recordImage },
  "record-reading": { caller: "hermes", run: recordReading },
  "recollection-cinemas": { caller: "hermes", run: recollectionCinemas },
  "resolve-pending-identification": { caller: "hermes", run: resolvePendingIdentification },
  "finish-collection": { caller: "hermes", run: finishCollection },
  "collection-summary": { caller: "hermes", run: collectionSummary },
  "record-site-reversion": { caller: "hermes", run: recordSiteReversion },
  "record-site-publication": { caller: "hermes", run: recordSitePublication },
  "daily-collection-status": { caller: "watchman", run: dailyCollectionStatus },
};

export type Options = {
  database: SupabaseClient;
  hermesToken: string | undefined;
  watchmanToken: string | undefined;
  // Lets local tests fix the clock through the x-ingestion-clock header.
  // Never enabled in production.
  clockOverride: boolean;
};

export async function handle(request: Request, options: Options): Promise<Response> {
  if (!options.hermesToken) {
    console.error("INGESTION_HERMES_TOKEN is not set");
    return failure(503, "not_configured", "A ingestão está sem o token do Hermes configurado.");
  }
  const caller = await identify(request, options);
  if (!caller) {
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
  if (operation.caller !== caller) {
    return failure(403, "forbidden", "Este token não alcança esta operação.");
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
    return await operation.run(body, { database: options.database, now });
  } catch (error) {
    console.error(error);
    return failure(500, "internal_error", "Erro interno da ingestão.");
  }
}

async function identify(request: Request, options: Options): Promise<Caller | null> {
  if (options.hermesToken && await hasToken(request, options.hermesToken)) return "hermes";
  if (options.watchmanToken && await hasToken(request, options.watchmanToken)) return "watchman";
  return null;
}

function clock(request: Request, allowed: boolean): Date | null {
  const header = request.headers.get("x-ingestion-clock");
  if (!allowed || header === null) return new Date();
  const date = new Date(header);
  return Number.isNaN(date.getTime()) ? null : date;
}
