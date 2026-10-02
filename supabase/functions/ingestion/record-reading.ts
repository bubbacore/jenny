import { z } from "zod";
import type { Context } from "./handler.ts";
import { failure, invalidRequest, type Issue, json } from "./http.ts";
import { Reading } from "./reading-contract.ts";

const RecordReadingRequest = z.strictObject({
  reading_id: z.uuid(),
  collection_release: z.string().regex(/^v\d+\.\d+\.\d+$/),
  reading: Reading,
});

type Alert = {
  type: string;
  subject: string;
  effect: "open" | "inform" | "resolve";
  text: string;
};

type Recorded =
  | {
    reading_id: string;
    result: "success" | "failure";
    failure_type?: "error" | "incomplete" | "outdated";
    reason?: string;
    sessions: Record<string, number>;
    alerts: Alert[];
  }
  | {
    refusal:
      | { code: "unknown_reading" | "reading_closed" | "reservation_expired" }
      | { code: "invalid_reading"; issues: Issue[] };
  };

// Records the reading of a reserved cinema and returns the result with the
// alerts to send. A successful reading replaces the cinema's whole
// programação, and a failed one erases it.
export async function recordReading(body: unknown, { database, now }: Context): Promise<Response> {
  const parsed = RecordReadingRequest.safeParse(body);
  if (!parsed.success) {
    return invalidRequest(
      "A requisição não segue o contrato do registro da leitura.",
      parsed.error,
    );
  }

  const { reading_id, collection_release, reading } = parsed.data;
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
