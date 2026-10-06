// deno-lint-ignore-file no-explicit-any
import { assertEquals } from "@std/assert";
import { callIngestion, readView } from "./local.ts";
import { at, movie, newTmdbId, newWeek, read, session } from "./reading.ts";

const UPDATED_AT = "2026-10-12T07:00:00-03:00";

function updateRatings(movies: unknown[], clock = UPDATED_AT) {
  return callIngestion("update-ratings", { movies }, { clock });
}

// Puts a new movie in the catalog, with an accepted session, and returns its
// TMDB id.
async function newMovie(): Promise<number> {
  const tmdbId = newTmdbId();
  const monday = newWeek();
  const response = await read("cine-alquimia", "ingresso_com", [movie("a", tmdbId)], [
    session("a", `${monday}T20:00`),
  ], at(monday, "08:00"));
  assertEquals(response.body.result, "success", JSON.stringify(response.body));
  return tmdbId;
}

async function ratings(tmdbId: number) {
  const [row] = await readView(
    "movies",
    `tmdb_id=eq.${tmdbId}&select=imdb_rating,imdb_votes,tomatometer,tomatometer_source,ratings_updated_at`,
  );
  return row;
}

async function siteRatings(tmdbId: number) {
  const [row] = await readView(
    "site_movies",
    `tmdb_id=eq.${tmdbId}&select=imdb_rating,imdb_votes,tomatometer`,
  );
  return row;
}

Deno.test("as notas de um filme são atualizadas com a origem e a data, e chegam à visão do build", async () => {
  const tmdbId = await newMovie();

  const { status, body } = await updateRatings([{
    tmdb_id: tmdbId,
    imdb: { rating: 7.3, votes: 152340 },
    tomatometer: { score: 88, source: "omdb" },
  }]);

  assertEquals(status, 200, JSON.stringify(body));
  assertEquals(body, { updated_movies: 1 });
  assertEquals(await ratings(tmdbId), {
    imdb_rating: 7.3,
    imdb_votes: 152340,
    tomatometer: 88,
    tomatometer_source: "omdb",
    ratings_updated_at: "2026-10-12T10:00:00+00:00",
  });
  assertEquals(await siteRatings(tmdbId), {
    imdb_rating: 7.3,
    imdb_votes: 152340,
    tomatometer: 88,
  });
});

Deno.test("a atualização seguinte substitui as notas, e uma nota ausente fica sem valor", async () => {
  const tmdbId = await newMovie();
  await updateRatings([{
    tmdb_id: tmdbId,
    imdb: { rating: 6, votes: 900 },
    tomatometer: { score: 40, source: "rotten_tomatoes_site" },
  }]);

  const { body } = await updateRatings([{
    tmdb_id: tmdbId,
    imdb: { rating: 6.4, votes: 1200 },
    tomatometer: null,
  }], "2026-10-19T07:00:00-03:00");

  assertEquals(body, { updated_movies: 1 });
  assertEquals(await ratings(tmdbId), {
    imdb_rating: 6.4,
    imdb_votes: 1200,
    tomatometer: null,
    tomatometer_source: null,
    ratings_updated_at: "2026-10-19T10:00:00+00:00",
  });
});

Deno.test("um filme fora do acervo recusa a atualização inteira", async () => {
  const known = await newMovie();
  const outside = newTmdbId();

  const { status, body } = await updateRatings([
    { tmdb_id: known, imdb: { rating: 8, votes: 10 }, tomatometer: null },
    { tmdb_id: outside, imdb: null, tomatometer: null },
  ]);

  assertEquals(status, 400);
  assertEquals(body.error.code, "unknown_movie");
  assertEquals(body.error.issues, [{
    path: "/movies/1/tmdb_id",
    message: "Nenhum filme do acervo tem este identificador do TMDB.",
  }]);
  assertEquals((await ratings(known)).ratings_updated_at, null);
});

Deno.test("a atualização de notas recusa o que foge do contrato, citando o caminho", async () => {
  const tmdbId = await newMovie();
  const { status, body } = await updateRatings([
    {
      tmdb_id: tmdbId,
      imdb: { rating: 7.35, votes: 10 },
      tomatometer: { score: 101, source: "omdb" },
    },
    { tmdb_id: tmdbId, imdb: null },
  ]);

  assertEquals(status, 400);
  assertEquals(body.error.code, "invalid_request");
  assertEquals(
    body.error.issues.map((issue: any) => issue.path).sort(),
    ["/movies/0/imdb/rating", "/movies/0/tomatometer/score", "/movies/1/tomatometer"],
  );

  const repeated = await updateRatings([
    { tmdb_id: tmdbId, imdb: null, tomatometer: null },
    { tmdb_id: tmdbId, imdb: null, tomatometer: null },
  ]);
  assertEquals(repeated.body.error.issues, [{
    path: "/movies/1/tmdb_id",
    message: "Filme repetido.",
  }]);
});
