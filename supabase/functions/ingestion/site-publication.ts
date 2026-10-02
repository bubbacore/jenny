import { z } from "zod";
import type { Context } from "./handler.ts";
import { invalidRequest, json } from "./http.ts";

const EmptyRequest = z.strictObject({});

// Records a reversion of the site publication asked by the owner, which
// suspends the automatic publication.
export function recordSiteReversion(body: unknown, context: Context): Promise<Response> {
  return record("record_site_reversion", "do registro da reversão", body, context);
}

// Records a site publication asked by the owner, which ends the suspension of
// the automatic publication.
export function recordSitePublication(body: unknown, context: Context): Promise<Response> {
  return record("record_site_publication", "do registro da publicação do site", body, context);
}

async function record(
  operation: string,
  contract: string,
  body: unknown,
  { database, now }: Context,
): Promise<Response> {
  const parsed = EmptyRequest.safeParse(body);
  if (!parsed.success) {
    return invalidRequest(`A requisição não segue o contrato ${contract}.`, parsed.error);
  }

  const { data, error } = await database.rpc(operation, { reference_time: now.toISOString() });
  if (error) throw error;

  return json(data);
}
