import { z } from "zod";
import type { Context } from "./handler.ts";
import { failure, invalidRequest, json } from "./http.ts";
import { slug } from "./reading-contract.ts";

const StartReadingRequest = z.strictObject({ collection_id: z.uuid(), cinema: slug });

type Started =
  | { reading_id: string; cinema: string; expires_at: string }
  | {
    refusal:
      | {
        code:
          | "unknown_collection"
          | "collection_finished"
          | "unknown_cinema"
          | "cinema_not_in_collection";
      }
      | { code: "reading_in_progress"; expires_at: string };
  };

// Reserves the cinema for a reading inside a collection that covers it.
// Another reading of the same cinema is refused until this one is recorded or
// its reservation expires.
export async function startReading(body: unknown, { database, now }: Context): Promise<Response> {
  const parsed = StartReadingRequest.safeParse(body);
  if (!parsed.success) {
    return invalidRequest("A requisição não segue o contrato do início da leitura.", parsed.error);
  }

  const { collection_id, cinema } = parsed.data;
  const { data, error } = await database.rpc("start_reading", {
    collection_id,
    cinema_slug: cinema,
    reference_time: now.toISOString(),
  });
  if (error) throw error;

  const started = data as Started;
  if (!("refusal" in started)) return json(started, 201);

  const { refusal } = started;
  switch (refusal.code) {
    case "unknown_collection":
      return failure(400, "unknown_collection", "A coleta não foi iniciada.", [
        { path: "/collection_id", message: "Nenhuma coleta tem este identificador." },
      ]);
    case "collection_finished":
      return failure(409, "collection_finished", "Esta coleta já terminou.");
    case "unknown_cinema":
      return failure(400, "unknown_cinema", "O cinema não está no plano.", [
        { path: "/cinema", message: `Cinema desconhecido ou inativo: ${cinema}.` },
      ]);
    case "cinema_not_in_collection":
      return failure(400, "cinema_not_in_collection", "A coleta não cobre este cinema.", [
        { path: "/cinema", message: `O cinema ${cinema} está fora desta coleta.` },
      ]);
  }
  return failure(
    409,
    "reading_in_progress",
    `Já há uma leitura do cinema ${cinema} em andamento, com a reserva até ${refusal.expires_at}.`,
  );
}
