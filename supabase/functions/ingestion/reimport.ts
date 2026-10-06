import { z } from "zod";
import type { Context } from "./handler.ts";
import { failure, invalidRequest, type Issue, json, pointer } from "./http.ts";
import { Person, Tmdb, tmdbId } from "./reading-contract.ts";

const chosenIds = z.array(tmdbId).min(1).refine((ids) => new Set(ids).size === ids.length, {
  message: "Identificadores repetidos.",
});

// The weekly round covers the movies with sessions; the manual round, the
// chosen movies and people, or the whole catalog when nothing is chosen.
const ReimportPlanRequest = z.strictObject({
  type: z.enum(["weekly", "manual"]),
  movies: chosenIds.optional().describe("Os identificadores do TMDB dos filmes escolhidos."),
  people: chosenIds.optional().describe("Os identificadores do TMDB das pessoas escolhidas."),
}).superRefine((request, context) => {
  if (request.type !== "weekly") return;
  for (const field of ["movies", "people"] as const) {
    if (request[field]) {
      context.addIssue({
        code: "custom",
        path: [field],
        message: "A rodada semanal cobre os filmes em exibição, sem escolha.",
      });
    }
  }
});

const ReimportRequest = z.strictObject({
  reimport_id: z.uuid(),
  movies: z.array(z.strictObject({
    tmdb_id: tmdbId,
    tmdb: Tmdb.nullable().describe(
      "Todos os dados que o TMDB tem do filme, com os créditos e os caminhos das imagens, " +
        "ou null quando o TMDB não tem mais o filme. Um dado ausente sumiu do TMDB.",
    ),
  })),
  people: z.array(z.strictObject({
    tmdb_id: tmdbId,
    tmdb: Person.omit({ tmdb_id: true }).nullable().describe(
      "A pessoa no TMDB, ou null quando o TMDB não tem mais a pessoa.",
    ),
  })),
}).superRefine((request, context) => {
  for (const field of ["movies", "people"] as const) {
    const seen = new Set<number>();
    request[field].forEach((item, index) => {
      if (seen.has(item.tmdb_id)) {
        context.addIssue({
          code: "custom",
          path: [field, index, "tmdb_id"],
          message: "Identificador repetido.",
        });
      }
      seen.add(item.tmdb_id);
    });
  }
});

type Planned =
  | { reimport_id: string; movies: unknown[]; people: unknown[] }
  | { refusal: { code: "unknown_catalog_item"; movies: number[]; people: number[] } };

type Reimported =
  | { reimport_id: string; movies: number; people: number; losses: number; alerts: unknown[] }
  | {
    refusal:
      | { code: "unknown_reimport" | "reimport_closed" }
      | { code: "invalid_reimport"; issues: Issue[] };
  };

// Starts a reimport and returns its plan: the movies, with the TMDB and IMDb
// ids, the titles and the year, and the chosen people.
export async function reimportPlan(body: unknown, { database, now }: Context): Promise<Response> {
  const parsed = ReimportPlanRequest.safeParse(body);
  if (!parsed.success) {
    return invalidRequest(
      "A requisição não segue o contrato do plano da reimportação.",
      parsed.error,
    );
  }

  const { type, movies, people } = parsed.data;
  const { data, error } = await database.rpc("reimport_plan", {
    reimport_type: type,
    movie_tmdb_ids: movies ?? null,
    person_tmdb_ids: people ?? null,
    reference_time: now.toISOString(),
  });
  if (error) throw error;

  const planned = data as Planned;
  if (!("refusal" in planned)) return json(planned);

  return failure(400, "unknown_catalog_item", "Há filmes ou pessoas fora do acervo.", [
    ...planned.refusal.movies.map((index) => ({
      path: pointer(["movies", index]),
      message: "Nenhum filme do acervo tem este identificador do TMDB.",
    })),
    ...planned.refusal.people.map((index) => ({
      path: pointer(["people", index]),
      message: "Nenhuma pessoa do acervo tem este identificador do TMDB.",
    })),
  ]);
}

// Finishes a reimport with the data read in TMDB. What changed is updated,
// and what vanished from TMDB stays in the catalog. Returns the alert with
// the new losses, when there are any.
export async function reimport(body: unknown, { database, now }: Context): Promise<Response> {
  const parsed = ReimportRequest.safeParse(body);
  if (!parsed.success) {
    return invalidRequest("A requisição não segue o contrato da reimportação.", parsed.error);
  }

  const { reimport_id, movies, people } = parsed.data;
  const { data, error } = await database.rpc("reimport", {
    reimport_id,
    movies,
    people,
    reference_time: now.toISOString(),
  });
  if (error) throw error;

  const reimported = data as Reimported;
  if (!("refusal" in reimported)) return json(reimported);

  const { refusal } = reimported;
  switch (refusal.code) {
    case "unknown_reimport":
      return failure(400, "unknown_reimport", "A reimportação não foi iniciada.", [
        {
          path: "/reimport_id",
          message: "Nenhuma reimportação iniciada tem este identificador.",
        },
      ]);
    case "reimport_closed":
      return failure(409, "reimport_closed", "Esta reimportação já terminou.");
    case "invalid_reimport":
      return failure(
        400,
        "invalid_reimport",
        "A reimportação não confere com o plano ou com as imagens gravadas.",
        refusal.issues,
      );
  }
}
