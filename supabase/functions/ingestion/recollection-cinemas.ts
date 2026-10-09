import { z } from "zod";
import type { Context } from "./handler.ts";
import { invalidRequest, json } from "./http.ts";

const RecollectionCinemasRequest = z.strictObject({});

// The active cinemas whose last finished reading of the day failed or that
// have no finished reading on the day yet, for the Hermes to read again. The
// list is empty from 22h on, in each cinema's city.
export async function recollectionCinemas(
  body: unknown,
  { database, now }: Context,
): Promise<Response> {
  const parsed = RecollectionCinemasRequest.safeParse(body);
  if (!parsed.success) {
    return invalidRequest(
      "A requisição não segue o contrato dos cinemas para recoleta.",
      parsed.error,
    );
  }

  const { data, error } = await database.rpc("recollection_cinemas", {
    reference_time: now.toISOString(),
  });
  if (error) throw error;

  return json(data);
}
