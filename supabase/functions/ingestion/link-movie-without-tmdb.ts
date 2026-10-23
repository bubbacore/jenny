import { z } from "zod";
import type { Context } from "./handler.ts";
import { failure, invalidRequest, json } from "./http.ts";
import { tmdbId } from "./reading-contract.ts";

const LinkMovieWithoutTmdbRequest = z.strictObject({
  source_title: z.string().regex(/\S/, { message: "Não pode ficar em branco." }),
  tmdb_id: tmdbId,
});

type Linked =
  | { recollection_cinemas: string[] }
  | { refusal: { code: "unknown_movie_without_tmdb" } };

// Links the movie without TMDB of a source title to the TMDB movie the owner
// chose, in every cinema where it has sessions. Returns those cinemas, so the
// Hermes recollects them and the sessions move to the TMDB movie.
export async function linkMovieWithoutTmdb(
  body: unknown,
  { database, now }: Context,
): Promise<Response> {
  const parsed = LinkMovieWithoutTmdbRequest.safeParse(body);
  if (!parsed.success) {
    return invalidRequest(
      "A requisição não segue o contrato da ligação do filme sem TMDB.",
      parsed.error,
    );
  }

  const { source_title, tmdb_id } = parsed.data;
  const { data, error } = await database.rpc("link_movie_without_tmdb", {
    source_title,
    tmdb_id,
    reference_time: now.toISOString(),
  });
  if (error) throw error;

  const linked = data as Linked;
  if (!("refusal" in linked)) return json(linked);

  return failure(
    400,
    "unknown_movie_without_tmdb",
    "Nenhum filme sem TMDB tem este título na fonte. Só um filme sem TMDB pode ser ligado a um " +
      "filme do TMDB.",
    [{
      path: "/source_title",
      message: "Use o título na fonte de um filme sem TMDB, como o plano da coleta o lista.",
    }],
  );
}
