import { z } from "zod";
import type { Context } from "./handler.ts";
import { invalidRequest, json } from "./http.ts";

const DailyCollectionStatusRequest = z.strictObject({});

// Whether today's daily collection has finished. The collection watchman asks
// it at 12h, without depending on the Hermes.
export async function dailyCollectionStatus(
  body: unknown,
  { database, now }: Context,
): Promise<Response> {
  const parsed = DailyCollectionStatusRequest.safeParse(body);
  if (!parsed.success) {
    return invalidRequest("A requisição não segue o contrato da coleta do dia.", parsed.error);
  }

  const { data, error } = await database.rpc("daily_collection_status", {
    reference_time: now.toISOString(),
  });
  if (error) throw error;

  return json(data);
}
