import { z } from "zod";
import type { Context } from "./handler.ts";
import { invalidRequest, json } from "./http.ts";

// daily: the summary at the end of the daily collection; evening: the one at
// 22h, sent only when some cinema spent the day without success.
const CollectionSummaryRequest = z.strictObject({ summary: z.enum(["daily", "evening"]) });

export async function collectionSummary(
  body: unknown,
  { database, now }: Context,
): Promise<Response> {
  const parsed = CollectionSummaryRequest.safeParse(body);
  if (!parsed.success) {
    return invalidRequest("A requisição não segue o contrato do resumo de coleta.", parsed.error);
  }

  const { data, error } = await database.rpc("collection_summary", {
    summary: parsed.data.summary,
    reference_time: now.toISOString(),
  });
  if (error) throw error;

  return json(data);
}
