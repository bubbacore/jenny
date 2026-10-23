// deno-lint-ignore-file no-explicit-any
import { assert, assertEquals } from "@std/assert";
import { callIngestion, readView } from "./local.ts";
import {
  addDays,
  at,
  collect,
  movie,
  newTmdbId,
  newWeek,
  read,
  session,
  showtimes,
} from "./reading.ts";

// Source titles new to every run, because the movies without TMDB of earlier
// runs stay in the catalog under their normalized source titles.
const run = crypto.randomUUID().slice(0, 8);

// A movie without TMDB as the Hermes sends it: no proposed movie, and the data
// of the main source in place of the TMDB data.
function withoutTmdb(
  key: string,
  sourceTitle: string,
  data: Record<string, unknown> = {},
  extra: Record<string, unknown> = {},
) {
  return {
    key,
    source_title: sourceTitle,
    tmdb_id: null,
    tmdb_search_top_id: null,
    without_tmdb: { title: sourceTitle, ...data },
    ...extra,
  };
}

function alertsOf(type: string, alerts: any[]) {
  return alerts.filter((alert) => alert.type === type);
}

async function siteMovie(slug: string): Promise<any> {
  const [found] = await readView("site_movies", `slug=eq.${slug}`);
  return found;
}

// The movie of each session of the cinema, in the order of the view.
async function showtimeMovies(cinema: string): Promise<string[]> {
  return (await showtimes(cinema)).map((row) => row.movie);
}

async function moviesWithoutTmdb(): Promise<any[]> {
  const { status, body } = await callIngestion("collection-plan", {
    collection_type: "manual",
    cinemas: ["cine-alquimia"],
  });
  assertEquals(status, 200, JSON.stringify(body));
  return body.movies_without_tmdb;
}

Deno.test("um filme sem TMDB tem as sessões aceitas, sem falha nem identificação pendente, e aparece nas visões do site só com os dados da fonte", async () => {
  const day = newWeek();
  const title = `Gustavo Mioto Em Inconfundível Tour ${run}`;
  const other = `Hybe Cheering Party ${run}`;
  const { status, body } = await read("cinemark-shopping-jardins", "ingresso_com", [
    movie("tmdb", newTmdbId()),
    withoutTmdb("show", title, { year: 2026, duration_minutes: 72 }, { content_rating: "12" }),
    withoutTmdb("festival", `${other} - Hybe Cine Fest 2026`, { title: other }, {
      tmdb_search_top_id: 1797226,
      overview: "Sinopse da fonte.",
      trailer: { url: "https://www.youtube.com/watch?v=abcdefghijk" },
    }),
  ], [
    session("tmdb", `${day}T19:00`),
    session("show", `${day}T19:00`),
    session("show", `${day}T21:00`),
    session("festival", `${day}T19:00`),
  ], at(day, "08:00"));

  assertEquals(status, 200, JSON.stringify(body));
  assertEquals(body.result, "success");
  assertEquals(body.sessions, { received: 4, discarded: 0, accepted: 4, retained: 0 });
  assertEquals(alertsOf("pending-identification", body.alerts), []);

  const slug = `gustavo-mioto-em-inconfundivel-tour-${run}`;
  const shown = await showtimeMovies("cinemark-shopping-jardins");
  assertEquals(shown.length, 4);
  assertEquals(shown.filter((movie) => movie === slug).length, 2);
  assertEquals(await siteMovie(slug), {
    slug,
    tmdb_id: null,
    title,
    original_title: title,
    imdb_id: null,
    year: 2026,
    countries: null,
    original_language: null,
    runtime_minutes: 72,
    overview: null,
    poster: null,
    trailer: null,
    genres: [],
    directors: [],
    cast: [],
    content_rating: "12",
    imdb_rating: null,
    imdb_votes: null,
    tomatometer: null,
    rotten_tomatoes_url: null,
    certified_fresh: false,
  });

  const festival = await siteMovie(`hybe-cheering-party-${run}`);
  assertEquals(festival.title, other);
  assertEquals(festival.overview, null);
  assertEquals(festival.trailer, null);
});

Deno.test("um filme sem TMDB sem os dados da fonte, sem o título neles ou com filme proposto é erro de contrato", async () => {
  const day = newWeek();
  const cases: [string, Record<string, unknown>, string[]][] = [
    ["sem without_tmdb", { without_tmdb: undefined }, ["/reading/movies/0/without_tmdb"]],
    ["sem o título", { without_tmdb: { year: 2026 } }, ["/reading/movies/0/without_tmdb/title"]],
    ["título em branco", { without_tmdb: { title: " " } }, [
      "/reading/movies/0/without_tmdb/title",
    ]],
    ["duração zerada", { without_tmdb: { title: "Show", duration_minutes: 0 } }, [
      "/reading/movies/0/without_tmdb/duration_minutes",
    ]],
    ["com os dados do TMDB", { tmdb: { title: "Show", original_title: "Show" } }, [
      "/reading/movies/0/tmdb",
    ]],
    ["com o título do filme proposto", { tmdb_title: "Show" }, ["/reading/movies/0/tmdb_title"]],
    ["com o identificador do TMDB", { tmdb_id: 9800001, tmdb_search_top_id: 9800001 }, [
      "/reading/movies/0/without_tmdb",
    ]],
  ];

  for (const [name, change, paths] of cases) {
    const entry: Record<string, unknown> = { ...withoutTmdb("show", `Show ${run}`), ...change };
    const response = await callIngestion("record-reading", {
      reading_id: crypto.randomUUID(),
      collection_release: "v0.1.0",
      reading: {
        cinema: "cine-alquimia",
        source: "ingresso_com",
        status: "ok",
        movies: [JSON.parse(JSON.stringify(entry))],
        sessions: [session("show", `${day}T19:00`)],
      },
    });
    assertEquals(response.status, 400, name);
    assertEquals(response.body.error.code, "invalid_request", name);
    assertEquals(response.body.error.issues.map((issue: any) => issue.path), paths, name);
  }
});

Deno.test("duas sessões no mesmo horário e na mesma sala são repetidas só quando são do mesmo filme sem TMDB", async () => {
  const day = newWeek();
  const sessions = [session("one", `${day}T19:00`), session("two", `${day}T19:00`)];

  const different = await read(
    "cine-alquimia",
    "ingresso_com",
    [
      withoutTmdb("one", `Show Um ${run}`),
      withoutTmdb("two", `Show Dois ${run}`),
    ],
    sessions,
    at(day, "08:00"),
  );
  assertEquals(different.body.result, "success", JSON.stringify(different.body));
  assertEquals(different.body.sessions.accepted, 2);

  const same = await callIngestion("record-reading", {
    reading_id: crypto.randomUUID(),
    collection_release: "v0.1.0",
    reading: {
      cinema: "cine-alquimia",
      source: "ingresso_com",
      status: "ok",
      movies: [withoutTmdb("one", `Show Um ${run}`), withoutTmdb("two", `SHOW  um ${run}`)],
      sessions,
    },
  });
  assertEquals(same.status, 400);
  assertEquals(same.body.error.issues.map((issue: any) => issue.path), ["/reading/sessions/1"]);
});

Deno.test("o mesmo título na fonte normalizado é o mesmo filme sem TMDB em cinemas diferentes", async () => {
  const day = newWeek();
  const slug = `cine-concerto-${run}`;
  const first = await read(
    "cine-alquimia",
    "ingresso_com",
    [
      withoutTmdb("show", `Cine Concerto ${run}`),
    ],
    [session("show", `${day}T19:00`)],
    at(day, "08:00"),
  );
  assertEquals(first.body.result, "success", JSON.stringify(first.body));

  const second = await read(
    "cinesercla-premio",
    "cinesercla_site",
    [
      withoutTmdb("show", `  CINE   CONCÉRTO ${run} `, { title: `CINE CONCÉRTO ${run}` }),
    ],
    [session("show", `${day}T20:00`)],
    at(day, "08:00"),
  );
  assertEquals(second.body.result, "success", JSON.stringify(second.body));

  assertEquals(await showtimeMovies("cine-alquimia"), [slug]);
  assertEquals(await showtimeMovies("cinesercla-premio"), [slug]);
  assertEquals((await siteMovie(slug)).title, `Cine Concerto ${run}`);
  assertEquals(
    (await moviesWithoutTmdb()).filter((listed) =>
      listed.normalized_source_title === `cine concerto ${run}`
    ).length,
    1,
  );
});

Deno.test("o identificador para o endereço do filme sem TMDB vem do título mostrado, com o ano e um número nas colisões, e nunca muda", async () => {
  const day = newWeek();
  const base = `noite-de-gala-${run}`;
  const shown = `Noite de Gala ${run}`;

  // Each spelling of the source title is a movie of its own, with the same
  // title shown, entering the catalog in its own reading.
  const entries: [string, Record<string, unknown>, string][] = [
    [`${shown} (Leg)`, { year: 2026 }, base],
    [`${shown} (Dub)`, { year: 2026 }, `${base}-2`],
    [`${shown} 3D`, {}, `${base}-3`],
    [`${shown} (Nac)`, { year: 2025 }, `${base}-2025`],
  ];
  for (const [index, [sourceTitle, data, slug]] of entries.entries()) {
    const { body } = await read(
      "cine-alquimia",
      "ingresso_com",
      [
        withoutTmdb("show", sourceTitle, { title: shown, ...data }),
      ],
      [session("show", `${day}T19:00`)],
      at(day, `08:0${index}`),
    );
    assertEquals(body.result, "success", JSON.stringify(body));
    assertEquals(await showtimeMovies("cine-alquimia"), [slug], sourceTitle);
  }

  const later = await read(
    "cine-alquimia",
    "ingresso_com",
    [
      withoutTmdb("first", `Noite de Gala ${run} (Leg)`, { title: `Gala ${run}`, year: 2027 }),
    ],
    [session("first", `${day}T14:00`)],
    at(day, "09:00"),
  );
  assertEquals(later.body.result, "success", JSON.stringify(later.body));
  assertEquals(await showtimeMovies("cine-alquimia"), [base]);
  const kept = await siteMovie(base);
  assertEquals([kept.title, kept.year], [shown, 2026]);
});

Deno.test("o alerta movie-without-tmdb sai na primeira aparição em cada cinema e não se repete", async () => {
  const day = newWeek();
  const title = `Ópera ao Vivo ${run}`;
  const entry = withoutTmdb("show", title);
  const sessions = [session("show", `${day}T19:00`), session("show", `${day}T21:00`)];
  const subject = `movie-without-tmdb:cinemark-riomar:opera ao vivo ${run}`;

  const first = await read("cinemark-riomar", "ingresso_com", [entry], sessions, at(day, "08:00"));
  assertEquals(alertsOf("movie-without-tmdb", first.body.alerts), [{
    type: "movie-without-tmdb",
    subject,
    effect: "inform",
    text:
      `Cinemark RioMar: o título na fonte "${title}" não foi encontrado no TMDB e entrou como ` +
      "filme sem TMDB, com 2 sessões aceitas. Confira se o TMDB tem o filme e a busca deixou de " +
      "achá-lo.",
  }]);

  const again = await read("cinemark-riomar", "ingresso_com", [entry], sessions, at(day, "10:00"));
  assertEquals(again.body.result, "success");
  assertEquals(alertsOf("movie-without-tmdb", again.body.alerts), []);

  const tomorrow = addDays(day, 1);
  const nextDay = await read(
    "cinemark-riomar",
    "ingresso_com",
    [entry],
    [session("show", `${tomorrow}T21:00`)],
    at(tomorrow, "08:00"),
  );
  assertEquals(nextDay.body.result, "success");
  assertEquals(alertsOf("movie-without-tmdb", nextDay.body.alerts), []);

  const otherCinema = await read("cine-alquimia", "ingresso_com", [entry], [
    session("show", `${day}T19:00`),
  ], at(day, "08:00"));
  assertEquals(
    alertsOf("movie-without-tmdb", otherCinema.body.alerts).map((alert) => alert.subject),
    [`movie-without-tmdb:cine-alquimia:opera ao vivo ${run}`],
  );
});

Deno.test("o plano da coleta lista o filme sem TMDB com os campos que faltam, e uma leitura seguinte completa só esses campos", async () => {
  const day = newWeek();
  const sourceTitle = `Stand-up Especial ${run}`;
  const normalized = `stand-up especial ${run}`;
  const listed = async () =>
    (await moviesWithoutTmdb()).find((movie) => movie.normalized_source_title === normalized);

  const first = await read(
    "cine-alquimia",
    "ingresso_com",
    [
      withoutTmdb("show", sourceTitle),
    ],
    [session("show", `${day}T19:00`)],
    at(day, "08:00"),
  );
  assertEquals(first.body.result, "success", JSON.stringify(first.body));
  assertEquals(await listed(), {
    normalized_source_title: normalized,
    missing: ["year", "duration_minutes"],
  });

  const second = await read(
    "cine-alquimia",
    "ingresso_com",
    [
      withoutTmdb("show", sourceTitle, {
        title: "Outro título",
        original_title: "Another title",
        year: 2026,
      }),
    ],
    [session("show", `${day}T19:00`)],
    at(day, "09:00"),
  );
  assertEquals(second.body.result, "success", JSON.stringify(second.body));
  assertEquals(await listed(), {
    normalized_source_title: normalized,
    missing: ["duration_minutes"],
  });

  const third = await read(
    "cine-alquimia",
    "ingresso_com",
    [
      withoutTmdb("show", sourceTitle, { year: 2020, duration_minutes: 95 }),
    ],
    [session("show", `${day}T19:00`)],
    at(day, "10:00"),
  );
  assertEquals(third.body.result, "success", JSON.stringify(third.body));
  assertEquals(await listed(), { normalized_source_title: normalized, missing: [] });

  const movie = await siteMovie(`stand-up-especial-${run}`);
  assertEquals(
    [movie.title, movie.original_title, movie.year, movie.runtime_minutes],
    [sourceTitle, sourceTitle, 2026, 95],
  );
});

Deno.test("uma leitura que propõe um filme do TMDB aceito para o mesmo título na fonte passa as sessões para ele, e o filme sem TMDB sai das visões do site", async () => {
  const day = newWeek();
  const sourceTitle = `Hybe Cheering Party - Hybe Cine Fest ${run}`;
  const slug = `hybe-cheering-party-hybe-cine-fest-${run}`;
  const tmdbId = newTmdbId();

  const before = await read(
    "cine-alquimia",
    "ingresso_com",
    [
      withoutTmdb("show", sourceTitle),
    ],
    [session("show", `${day}T19:00`)],
    at(day, "08:00"),
  );
  assertEquals(before.body.result, "success", JSON.stringify(before.body));
  assertEquals(await showtimeMovies("cine-alquimia"), [slug]);

  const found = await read(
    "cine-alquimia",
    "ingresso_com",
    [
      movie("show", tmdbId, { source_title: sourceTitle }),
    ],
    [session("show", `${day}T19:00`)],
    at(day, "09:00"),
  );
  assertEquals(found.body.result, "success", JSON.stringify(found.body));
  assertEquals(await showtimeMovies("cine-alquimia"), [`movie-${tmdbId}`]);
  assertEquals(await siteMovie(slug), undefined);
});

Deno.test("o filme sem TMDB fica fora do plano da reimportação e do plano das notas", async () => {
  const day = newWeek();
  const recorded = await read(
    "cine-alquimia",
    "ingresso_com",
    [
      withoutTmdb("show", `Sarau ${run}`),
    ],
    [session("show", `${day}T19:00`)],
    at(day, "08:00"),
  );
  assertEquals(recorded.body.result, "success", JSON.stringify(recorded.body));

  for (const type of ["weekly", "manual"]) {
    const { status, body } = await callIngestion("reimport-plan", { type });
    assertEquals(status, 200, JSON.stringify(body));
    assert(body.movies.length > 0, type);
    assert(body.movies.every((planned: any) => planned.tmdb_id !== null), type);
  }

  const collectionId = await collect("manual", at(day, "08:00"));
  const ratings = await callIngestion("ratings-plan", { collection_id: collectionId }, {
    clock: at(day, "08:00"),
  });
  assertEquals(ratings.status, 200, JSON.stringify(ratings.body));
  assert(ratings.body.movies.every((planned: any) => planned.tmdb_id !== null));
});
