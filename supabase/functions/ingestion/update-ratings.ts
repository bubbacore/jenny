import { z } from "zod";
import type { Context } from "./handler.ts";
import { failure, invalidRequest, json, pointer } from "./http.ts";

const MAX_INTEGER = 2_147_483_647;

// A rating with at most one decimal place, like IMDb's 7.3.
const oneDecimal = (min: number, max: number) =>
  z.number().min(min).max(max).refine(
    (value) => Number.isInteger(Number((value * 10).toFixed(6))),
    {
      message: "Use no máximo uma casa decimal.",
    },
  );

const UpdateRatingsRequest = z.strictObject({
  movies: z.array(z.strictObject({
    tmdb_id: z.int().positive().max(MAX_INTEGER),
    imdb: z.strictObject({
      rating: oneDecimal(1, 10),
      votes: z.int().positive().max(MAX_INTEGER),
    }).nullable().describe("A nota do IMDb com os votos, ou null quando o filme não tem nota."),
    tomatometer: z.strictObject({
      score: z.int().min(0).max(100),
      source: z.enum(["omdb", "rotten_tomatoes_site"]),
    }).nullable().describe("O Tomatometer com a origem, ou null quando o filme não tem."),
  })).min(1),
}).superRefine((request, context) => {
  const seen = new Set<number>();
  request.movies.forEach((movie, index) => {
    if (seen.has(movie.tmdb_id)) {
      context.addIssue({
        code: "custom",
        path: ["movies", index, "tmdb_id"],
        message: "Filme repetido.",
      });
    }
    seen.add(movie.tmdb_id);
  });
});

type Updated =
  | { updated_movies: number }
  | { refusal: { code: "unknown_movie"; indexes: number[] } };

// Records the weekly IMDb and Rotten Tomatoes ratings of the movies, with the
// date of the update. A null rating means the movie has none, and replaces
// what was kept.
export async function updateRatings(body: unknown, { database, now }: Context): Promise<Response> {
  const parsed = UpdateRatingsRequest.safeParse(body);
  if (!parsed.success) {
    return invalidRequest(
      "A requisição não segue o contrato da atualização de notas.",
      parsed.error,
    );
  }

  const { data, error } = await database.rpc("update_ratings", {
    movies: parsed.data.movies,
    reference_time: now.toISOString(),
  });
  if (error) throw error;

  const updated = data as Updated;
  if (!("refusal" in updated)) return json(updated);

  return failure(
    400,
    "unknown_movie",
    "Há filmes fora do acervo.",
    updated.refusal.indexes.map((index) => ({
      path: pointer(["movies", index, "tmdb_id"]),
      message: "Nenhum filme do acervo tem este identificador do TMDB.",
    })),
  );
}
