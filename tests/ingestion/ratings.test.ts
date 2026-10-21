// deno-lint-ignore-file no-explicit-any
import { assertEquals } from "@std/assert";
import { callIngestion, readView } from "./local.ts";
import {
  addDays,
  at,
  collect,
  finish,
  movie,
  newTmdbId,
  newWeek,
  read,
  session,
} from "./reading.ts";

const UPDATED_AT = "2026-10-12T07:00:00-03:00";

// The movie whose only sessions are in the inactive cinema, from the seed.
const INACTIVE_CINEMA_MOVIE = 9990001;

const moviePage = (id: number) => ({
  url: `https://www.rottentomatoes.com/m/movie_${id}`,
  kind: "movie_page",
});
const search = (id: number) => ({
  url: `https://www.rottentomatoes.com/search?search=Movie%20${id}`,
  kind: "search",
});

// Without a collection, as the weekly routine still calls it.
function updateRatings(movies: unknown[], clock = UPDATED_AT, collectionId?: string) {
  return callIngestion("update-ratings", {
    ...(collectionId ? { collection_id: collectionId } : {}),
    movies,
  }, { clock });
}

function ratingsPlan(collectionId: string, clock: string) {
  return callIngestion("ratings-plan", { collection_id: collectionId }, { clock });
}

// A movie with an IMDb id, the original title and the year, as TMDB gives
// them.
function ratedMovie(key: string, tmdbId: number) {
  return movie(key, tmdbId, {
    tmdb: {
      title: `Filme ${tmdbId}`,
      original_title: `Movie ${tmdbId}`,
      imdb_id: `tt${tmdbId}`,
      year: 2026,
    },
  });
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
    `tmdb_id=eq.${tmdbId}&select=imdb_rating,imdb_votes,tomatometer,tomatometer_source,` +
      "certified_fresh,ratings_updated_at",
  );
  return row;
}

async function rottenTomatoesLink(tmdbId: number) {
  const [row] = await readView(
    "movies",
    `tmdb_id=eq.${tmdbId}&select=rotten_tomatoes_url,rotten_tomatoes_url_kind`,
  );
  return row;
}

async function siteRatings(tmdbId: number) {
  const [row] = await readView(
    "site_movies",
    `tmdb_id=eq.${tmdbId}&select=imdb_rating,imdb_votes,tomatometer,rotten_tomatoes_url,` +
      "certified_fresh",
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
    certified_fresh: false,
    ratings_updated_at: "2026-10-12T10:00:00+00:00",
  });
  assertEquals(await siteRatings(tmdbId), {
    imdb_rating: 7.3,
    imdb_votes: 152340,
    tomatometer: 88,
    rotten_tomatoes_url: null,
    certified_fresh: false,
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
    certified_fresh: false,
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

Deno.test("o Certified Fresh entra com o Tomatometer do site do Rotten Tomatoes e sai quando o filme o perde ou fica sem Tomatometer", async () => {
  const tmdbId = await newMovie();
  const clock = at(newWeek(), "07:00");
  const collection = await collect("manual", clock);
  const update = (tomatometer: unknown) =>
    updateRatings(
      [{
        tmdb_id: tmdbId,
        imdb: { rating: 8.4, votes: 20000 },
        tomatometer,
        rotten_tomatoes_link: moviePage(tmdbId),
      }],
      clock,
      collection,
    );
  const certified = { score: 97, source: "rotten_tomatoes_site", certified_fresh: true };

  const first = await update(certified);
  assertEquals(first.status, 200, JSON.stringify(first.body));
  assertEquals((await ratings(tmdbId)).certified_fresh, true);
  assertEquals(await siteRatings(tmdbId), {
    imdb_rating: 8.4,
    imdb_votes: 20000,
    tomatometer: 97,
    rotten_tomatoes_url: moviePage(tmdbId).url,
    certified_fresh: true,
  });

  await update({ score: 68, source: "rotten_tomatoes_site", certified_fresh: false });
  assertEquals((await siteRatings(tmdbId)).certified_fresh, false);

  await update(certified);
  await update(null);
  assertEquals((await ratings(tmdbId)).certified_fresh, false);
  assertEquals((await siteRatings(tmdbId)).certified_fresh, false);
});

Deno.test("um Tomatometer sem o Certified Fresh, como o Hermes o enviava antes do selo, grava o filme sem ele", async () => {
  const tmdbId = await newMovie();
  await updateRatings([{
    tmdb_id: tmdbId,
    imdb: null,
    tomatometer: { score: 95, source: "rotten_tomatoes_site", certified_fresh: true },
  }]);

  const { status, body } = await updateRatings([{
    tmdb_id: tmdbId,
    imdb: null,
    tomatometer: { score: 95, source: "rotten_tomatoes_site" },
  }], "2026-10-19T07:00:00-03:00");

  assertEquals(status, 200, JSON.stringify(body));
  assertEquals(await ratings(tmdbId), {
    imdb_rating: null,
    imdb_votes: null,
    tomatometer: 95,
    tomatometer_source: "rotten_tomatoes_site",
    certified_fresh: false,
    ratings_updated_at: "2026-10-19T10:00:00+00:00",
  });
});

Deno.test("a atualização de notas recusa o Certified Fresh num Tomatometer do OMDb, citando o caminho", async () => {
  const tmdbId = await newMovie();

  const { status, body } = await updateRatings([
    {
      tmdb_id: tmdbId,
      imdb: null,
      tomatometer: { score: 90, source: "omdb", certified_fresh: true },
    },
    {
      tmdb_id: newTmdbId(),
      imdb: null,
      tomatometer: { score: 90, source: "rotten_tomatoes_site", certified_fresh: "sim" },
    },
  ]);

  assertEquals(status, 400);
  assertEquals(body.error.code, "invalid_request");
  assertEquals(body.error.issues.map((issue: any) => issue.path), [
    "/movies/0/tomatometer/certified_fresh",
    "/movies/1/tomatometer/certified_fresh",
  ]);
  assertEquals(
    body.error.issues[0].message,
    "O OMDb não informa o Certified Fresh. Ele vem só do site do Rotten Tomatoes.",
  );
  assertEquals((await ratings(tmdbId)).ratings_updated_at, null);
});

Deno.test("a atualização sem coleta mantém o link do Rotten Tomatoes guardado quando não o envia", async () => {
  const tmdbId = await newMovie();
  await updateRatings([{
    tmdb_id: tmdbId,
    imdb: null,
    tomatometer: { score: 70, source: "rotten_tomatoes_site" },
    rotten_tomatoes_link: moviePage(tmdbId),
  }]);

  const { status, body } = await updateRatings([{
    tmdb_id: tmdbId,
    imdb: null,
    tomatometer: { score: 71, source: "rotten_tomatoes_site" },
  }], "2026-10-19T07:00:00-03:00");

  assertEquals(status, 200, JSON.stringify(body));
  assertEquals(await rottenTomatoesLink(tmdbId), {
    rotten_tomatoes_url: moviePage(tmdbId).url,
    rotten_tomatoes_url_kind: "movie_page",
  });
});

Deno.test("o plano das notas devolve os filmes com sessões sem notas de hoje, no fuso da cidade, com o link guardado", async () => {
  const today = newWeek();
  const yesterday = addDays(today, -1);
  const [never, updatedYesterday, lateYesterday, updatedToday, withoutImdb] = [
    newTmdbId(),
    newTmdbId(),
    newTmdbId(),
    newTmdbId(),
    newTmdbId(),
  ];
  const movies = [
    ratedMovie("a", never),
    ratedMovie("b", updatedYesterday),
    ratedMovie("c", lateYesterday),
    ratedMovie("d", updatedToday),
    movie("e", withoutImdb),
  ];
  const response = await read(
    "cine-alquimia",
    "ingresso_com",
    movies,
    movies.map((entry, index) => session(entry.key, `${today}T${14 + index}:00`)),
    at(yesterday, "08:00"),
  );
  assertEquals(response.body.result, "success", JSON.stringify(response.body));

  const rated = (tmdbId: number, link: unknown = null) => ({
    tmdb_id: tmdbId,
    imdb: { rating: 7, votes: 100 },
    tomatometer: null,
    rotten_tomatoes_link: link,
  });
  await updateRatings(
    [rated(updatedYesterday, moviePage(updatedYesterday))],
    at(yesterday, "10:00"),
  );
  // 23:30 in Aracaju is already the next day in UTC.
  await updateRatings([rated(lateYesterday, search(lateYesterday))], at(yesterday, "23:30"));
  await updateRatings([rated(updatedToday)], at(today, "00:30"));

  const collection = await collect("manual", at(today, "07:00"));
  const { status, body } = await ratingsPlan(collection, at(today, "07:00"));

  assertEquals(status, 200, JSON.stringify(body));
  const ours = [never, updatedYesterday, lateYesterday, updatedToday, withoutImdb];
  assertEquals(body.movies.filter((planned: any) => ours.includes(planned.tmdb_id)), [
    {
      tmdb_id: never,
      imdb_id: `tt${never}`,
      original_title: `Movie ${never}`,
      year: 2026,
      rotten_tomatoes_link: null,
    },
    {
      tmdb_id: updatedYesterday,
      imdb_id: `tt${updatedYesterday}`,
      original_title: `Movie ${updatedYesterday}`,
      year: 2026,
      rotten_tomatoes_link: moviePage(updatedYesterday),
    },
    {
      tmdb_id: lateYesterday,
      imdb_id: `tt${lateYesterday}`,
      original_title: `Movie ${lateYesterday}`,
      year: 2026,
      rotten_tomatoes_link: search(lateYesterday),
    },
  ]);
});

Deno.test("o plano das notas deixa de fora o filme só com sessões em cinema inativo", async () => {
  assertEquals(await readView("movies", `tmdb_id=eq.${INACTIVE_CINEMA_MOVIE}&select=imdb_id`), [
    { imdb_id: `tt${INACTIVE_CINEMA_MOVIE}` },
  ]);
  const clock = at(newWeek(), "07:00");
  const collection = await collect("manual", clock);

  const { status, body } = await ratingsPlan(collection, clock);

  assertEquals(status, 200, JSON.stringify(body));
  assertEquals(
    body.movies.some((planned: any) => planned.tmdb_id === INACTIVE_CINEMA_MOVIE),
    false,
  );
});

Deno.test("o plano e a atualização de notas recusam uma coleta desconhecida ou já terminada", async () => {
  const tmdbId = await newMovie();
  const clock = at(newWeek(), "07:00");
  const finished = await collect("manual", clock, { site_publication: false });
  await finish(finished, clock);
  const update = (collectionId: string) =>
    updateRatings(
      [{ tmdb_id: tmdbId, imdb: null, tomatometer: null, rotten_tomatoes_link: null }],
      clock,
      collectionId,
    );

  for (
    const response of [
      await ratingsPlan(crypto.randomUUID(), clock),
      await update(crypto.randomUUID()),
    ]
  ) {
    assertEquals(response.status, 400);
    assertEquals(response.body.error.code, "unknown_collection");
    assertEquals(response.body.error.issues.map((issue: any) => issue.path), ["/collection_id"]);
  }
  for (const response of [await ratingsPlan(finished, clock), await update(finished)]) {
    assertEquals(response.status, 409);
    assertEquals(response.body.error.code, "collection_finished");
  }
  assertEquals((await ratings(tmdbId)).ratings_updated_at, null);

  const invalid = await callIngestion("ratings-plan", { collection_id: "coleta" }, { clock });
  assertEquals(invalid.status, 400);
  assertEquals(invalid.body.error.issues.map((issue: any) => issue.path), ["/collection_id"]);
});

Deno.test("a atualização de notas da coleta grava o link do Rotten Tomatoes, e uma nota ou um link ausentes apagam os guardados", async () => {
  const tmdbId = await newMovie();
  const clock = at(newWeek(), "07:00");
  const collection = await collect("manual", clock);

  const first = await updateRatings(
    [{
      tmdb_id: tmdbId,
      imdb: { rating: 8.1, votes: 5000 },
      tomatometer: { score: 93, source: "rotten_tomatoes_site" },
      rotten_tomatoes_link: moviePage(tmdbId),
    }],
    clock,
    collection,
  );

  assertEquals(first.status, 200, JSON.stringify(first.body));
  assertEquals(first.body, { updated_movies: 1 });
  assertEquals(await rottenTomatoesLink(tmdbId), {
    rotten_tomatoes_url: moviePage(tmdbId).url,
    rotten_tomatoes_url_kind: "movie_page",
  });
  assertEquals(await siteRatings(tmdbId), {
    imdb_rating: 8.1,
    imdb_votes: 5000,
    tomatometer: 93,
    rotten_tomatoes_url: moviePage(tmdbId).url,
    certified_fresh: false,
  });

  await updateRatings(
    [{
      tmdb_id: tmdbId,
      imdb: null,
      tomatometer: { score: 90, source: "omdb" },
      rotten_tomatoes_link: search(tmdbId),
    }],
    clock,
    collection,
  );
  assertEquals(await rottenTomatoesLink(tmdbId), {
    rotten_tomatoes_url: search(tmdbId).url,
    rotten_tomatoes_url_kind: "search",
  });

  await updateRatings(
    [{ tmdb_id: tmdbId, imdb: null, tomatometer: null, rotten_tomatoes_link: null }],
    clock,
    collection,
  );
  assertEquals(await siteRatings(tmdbId), {
    imdb_rating: null,
    imdb_votes: null,
    tomatometer: null,
    rotten_tomatoes_url: null,
    certified_fresh: false,
  });
  assertEquals(await rottenTomatoesLink(tmdbId), {
    rotten_tomatoes_url: null,
    rotten_tomatoes_url_kind: null,
  });
});

Deno.test("a atualização de notas da coleta exige o link e recusa um link fora do site do Rotten Tomatoes, citando o caminho", async () => {
  const tmdbId = await newMovie();
  const clock = at(newWeek(), "07:00");
  const collection = await collect("manual", clock);
  const links = [
    { url: `https://www.imdb.com/title/tt${tmdbId}/`, kind: "movie_page" },
    { url: "http://www.rottentomatoes.com/m/movie", kind: "movie_page" },
    { url: "https://rottentomatoes.com.example.com/m/movie", kind: "movie_page" },
    { url: "não é um link", kind: "movie_page" },
    { url: "https://www.rottentomatoes.com/search?search=Movie", kind: "movie_page" },
    { url: "https://www.rottentomatoes.com/m/movie", kind: "search" },
    { url: "https://www.rottentomatoes.com/m/movie", kind: "page" },
  ];

  const wrong = await updateRatings(
    links.map((link) => ({
      tmdb_id: newTmdbId(),
      imdb: null,
      tomatometer: null,
      rotten_tomatoes_link: link,
    })),
    clock,
    collection,
  );

  assertEquals(wrong.status, 400, JSON.stringify(wrong.body));
  assertEquals(wrong.body.error.code, "invalid_request");
  assertEquals(wrong.body.error.issues.map((issue: any) => issue.path), [
    "/movies/0/rotten_tomatoes_link/url",
    "/movies/1/rotten_tomatoes_link/url",
    "/movies/2/rotten_tomatoes_link/url",
    "/movies/3/rotten_tomatoes_link/url",
    "/movies/4/rotten_tomatoes_link/url",
    "/movies/5/rotten_tomatoes_link/url",
    "/movies/6/rotten_tomatoes_link/kind",
  ]);

  const missing = await updateRatings(
    [{ tmdb_id: tmdbId, imdb: null, tomatometer: null }],
    clock,
    collection,
  );
  assertEquals(missing.status, 400);
  assertEquals(missing.body.error.issues, [{
    path: "/movies/0/rotten_tomatoes_link",
    message: "Envie o link do Rotten Tomatoes, ou null sem ele.",
  }]);
  assertEquals((await ratings(tmdbId)).ratings_updated_at, null);
});
