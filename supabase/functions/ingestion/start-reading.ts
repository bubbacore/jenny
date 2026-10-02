import { z } from "zod";
import type { Context } from "./handler.ts";
import { failure, invalidRequest, json } from "./http.ts";
import { slug } from "./reading-contract.ts";

const StartReadingRequest = z.strictObject({ cinema: slug });

type Started =
  | { reading_id: string; cinema: string; expires_at: string }
  | { refusal: { code: "unknown_cinema" } | { code: "reading_in_progress"; expires_at: string } };

// Reserves the cinema for a reading. Another reading of the same cinema is
// refused until this one is recorded or its reservation expires.
export async function startReading(body: unknown, { database, now }: Context): Promise<Response> {
  const parsed = StartReadingRequest.safeParse(body);
  if (!parsed.success) {
    return invalidRequest("A requisição não segue o contrato do início da leitura.", parsed.error);
  }

  const { cinema } = parsed.data;
  const { data, error } = await database.rpc("start_reading", {
    cinema_slug: cinema,
    reference_time: now.toISOString(),
  });
  if (error) throw error;

  const started = data as Started;
  if (!("refusal" in started)) return json(started, 201);

  const { refusal } = started;
  if (refusal.code === "unknown_cinema") {
    return failure(400, "unknown_cinema", "O cinema não está no plano.", [
      { path: "/cinema", message: `Cinema desconhecido ou inativo: ${cinema}.` },
    ]);
  }
  return failure(
    409,
    "reading_in_progress",
    `Já há uma leitura do cinema ${cinema} em andamento, com a reserva até ${refusal.expires_at}.`,
  );
}
