import { z } from "zod";
import type { Context } from "./handler.ts";
import { failure, invalidRequest, json } from "./http.ts";
import { slug } from "./reading-contract.ts";

const ResolvePendingIdentificationRequest = z.strictObject({
  cinema: slug,
  source_title: z.string().regex(/\S/, { message: "Não pode ficar em branco." }),
  tmdb_id: z.int().positive().max(2_147_483_647),
});

type Resolved =
  | { recollection_cinema: string; alerts: unknown[] }
  | { refusal: { code: "unknown_identification" } };

// Resolves the pending identification of a source title in a cinema with the
// movie the owner chose. Returns the cinema to recollect and the alert that
// resolves the occurrence.
export async function resolvePendingIdentification(
  body: unknown,
  { database, now }: Context,
): Promise<Response> {
  const parsed = ResolvePendingIdentificationRequest.safeParse(body);
  if (!parsed.success) {
    return invalidRequest(
      "A requisição não segue o contrato da resolução de identificação pendente.",
      parsed.error,
    );
  }

  const { cinema, source_title, tmdb_id } = parsed.data;
  const { data, error } = await database.rpc("resolve_pending_identification", {
    cinema_slug: cinema,
    source_title,
    tmdb_id,
    reference_time: now.toISOString(),
  });
  if (error) throw error;

  const resolved = data as Resolved;
  if (!("refusal" in resolved)) return json(resolved);

  return failure(
    400,
    "unknown_identification",
    "O cinema não tem identificação pendente deste título na fonte.",
    [{ path: "/source_title", message: `Nenhuma identificação pendente em ${cinema}.` }],
  );
}
