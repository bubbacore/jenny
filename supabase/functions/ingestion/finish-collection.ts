import { z } from "zod";
import type { Context } from "./handler.ts";
import { failure, invalidRequest, json } from "./http.ts";

const FinishCollectionRequest = z.strictObject({ collection_id: z.uuid() });

type Finished =
  | { collection_id: string; site_publication: boolean; automatic_publication_suspended: boolean }
  | { refusal: { code: "unknown_collection" | "collection_finished" } };

// Ends the collection and says whether it ends with a site publication.
export async function finishCollection(
  body: unknown,
  { database, now }: Context,
): Promise<Response> {
  const parsed = FinishCollectionRequest.safeParse(body);
  if (!parsed.success) {
    return invalidRequest("A requisição não segue o contrato do fim da coleta.", parsed.error);
  }

  const { data, error } = await database.rpc("finish_collection", {
    collection_id: parsed.data.collection_id,
    reference_time: now.toISOString(),
  });
  if (error) throw error;

  const finished = data as Finished;
  if (!("refusal" in finished)) return json(finished);

  if (finished.refusal.code === "unknown_collection") {
    return failure(400, "unknown_collection", "A coleta não foi iniciada.", [
      { path: "/collection_id", message: "Nenhuma coleta tem este identificador." },
    ]);
  }
  return failure(409, "collection_finished", "Esta coleta já terminou.");
}
