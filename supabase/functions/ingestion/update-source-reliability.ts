import { z } from "zod";
import type { Context } from "./handler.ts";
import { invalidRequest, json } from "./http.ts";

const UpdateSourceReliabilityRequest = z.strictObject({});

// Calculates the source reliability, in the weekly routine. Returns the
// ranking with the reason of each place, whether it changed, and the alert to
// send when it did.
export async function updateSourceReliability(
  body: unknown,
  { database, now }: Context,
): Promise<Response> {
  const parsed = UpdateSourceReliabilityRequest.safeParse(body);
  if (!parsed.success) {
    return invalidRequest(
      "A requisição não segue o contrato da atualização da confiabilidade.",
      parsed.error,
    );
  }

  const { data, error } = await database.rpc("update_source_reliability", {
    reference_time: now.toISOString(),
  });
  if (error) throw error;

  return json(data);
}
