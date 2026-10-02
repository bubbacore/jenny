import { z } from "zod";
import type { Context } from "./handler.ts";
import { failure, invalidRequest, type Issue, json } from "./http.ts";
import { Reading } from "./reading-contract.ts";

const RecordReadingRequest = z.strictObject({
  reading_id: z.uuid(),
  collection_release: z.string().regex(/^v\d+\.\d+\.\d+$/),
  reading: Reading,
});

type Recorded =
  | { reading_id: string; result: "success"; sessions: Record<string, number>; alerts: unknown[] }
  | {
    refusal:
      | { code: "unknown_reading" | "reading_closed" | "reservation_expired" }
      | { code: "invalid_reading"; issues: Issue[] };
  };

// Records the reading of a reserved cinema, which replaces the cinema's whole
// programação, and returns the result with the alerts to send.
export async function recordReading(body: unknown, { database, now }: Context): Promise<Response> {
  const parsed = RecordReadingRequest.safeParse(body);
  if (!parsed.success) {
    return invalidRequest(
      "A requisição não segue o contrato do registro da leitura.",
      parsed.error,
    );
  }

  const { reading_id, collection_release, reading } = parsed.data;
  if (reading.status !== "ok") {
    return failure(
      422,
      "failed_reading_not_supported",
      "A ingestão ainda não registra leitura com falha.",
      [
        { path: "/reading/status", message: "Por enquanto, só leituras com status ok." },
      ],
    );
  }

  const { data, error } = await database.rpc("record_reading", {
    reading_id,
    collection_release,
    reading,
    reference_time: now.toISOString(),
  });
  if (error) throw error;

  const recorded = data as Recorded;
  if (!("refusal" in recorded)) return json(recorded);

  const { refusal } = recorded;
  switch (refusal.code) {
    case "unknown_reading":
      return failure(400, "unknown_reading", "A leitura não foi iniciada.", [
        { path: "/reading_id", message: "Nenhuma leitura iniciada tem este identificador." },
      ]);
    case "reading_closed":
      return failure(409, "reading_closed", "Esta leitura já foi registrada ou abandonada.");
    case "reservation_expired":
      return failure(
        409,
        "reservation_expired",
        "A reserva desta leitura expirou depois de 30 minutos. Inicie outra leitura do cinema.",
      );
    case "invalid_reading":
      return failure(
        400,
        "invalid_reading",
        "A leitura não confere com a reserva ou com o acervo.",
        refusal.issues,
      );
  }
}
