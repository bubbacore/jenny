// deno-lint-ignore-file no-explicit-any
import { assertEquals } from "@std/assert";
import { callIngestion, readView } from "./local.ts";
import { at, movie, newTmdbId, newWeek, post, read, session, showtimes } from "./reading.ts";

// The Cinema do Centro is read in the posts on its Instagram, the only source
// where the Hermes opens the movie videos.
const CINEMA = "cinema-do-centro";

// Source titles new to every run, so no resolution or pending identification
// of an earlier run applies.
const run = crypto.randomUUID().slice(0, 8);

const VIDEO_POST = "https://www.instagram.com/p/video-do-filme/";

// A movie identified by the movie video, as the Hermes sends it: the proposed
// movie with its TMDB data, the top result of the search by the source title
// and year, which found nothing, and what the video shows, with the top result
// of the search by the video's original title.
function identifiedByVideo(
  key: string,
  sourceTitle: string,
  tmdbId: number,
  videoTopId = tmdbId,
) {
  return movie(key, tmdbId, {
    source_title: sourceTitle,
    tmdb_search_top_id: null,
    tmdb_title: `Filme ${tmdbId}`,
    tmdb_year: 2025,
    tmdb: { title: `Filme ${tmdbId}`, original_title: `Movie ${tmdbId}`, year: 2025 },
    video_identification: videoIdentification(tmdbId, videoTopId),
  });
}

// What the video shows, with the top result of the search by its original
// title.
function videoIdentification(tmdbId: number, videoTopId = tmdbId) {
  return {
    post_url: VIDEO_POST,
    original_title: `Movie ${tmdbId}`,
    directors: ["Diretora Um", "Diretor Dois"],
    tmdb_search_top_id: videoTopId,
  };
}

function withoutTmdb(key: string, sourceTitle: string) {
  return {
    key,
    source_title: sourceTitle,
    tmdb_id: null,
    tmdb_search_top_id: null,
    without_tmdb: { title: sourceTitle },
  };
}

function alertsOf(type: string, alerts: any[]) {
  return alerts.filter((alert) => alert.type === type);
}

async function showtimeMovies(): Promise<string[]> {
  return (await showtimes(CINEMA)).map((row) => row.movie);
}

// The source titles resolved in the cinema, as the collection plan returns
// them to the Hermes.
async function resolvedSourceTitles(clock: string): Promise<any[]> {
  const { status, body } = await callIngestion("collection-plan", {
    collection_type: "manual",
    cinemas: [CINEMA],
  }, { clock });
  assertEquals(status, 200, JSON.stringify(body));
  return body.cinemas[0].resolved_source_titles;
}

Deno.test("a proposta pelo vídeo do filme que coincide com o primeiro resultado da busca pelo título original aceita as sessões, grava o título na fonte resolvido e informa o alerta movie-identified-by-video", async () => {
  const day = newWeek();
  const sourceTitle = `Sirât ${run}`;
  const normalized = `sirat ${run}`;
  const tmdbId = newTmdbId();

  // Without the video, the source title was a movie without TMDB.
  const before = await read(CINEMA, "instagram", [withoutTmdb("filme", sourceTitle)], [
    session("filme", `${day}T19:00`),
  ], at(day, "08:00"));
  assertEquals(before.body.result, "success", JSON.stringify(before.body));
  assertEquals(await showtimeMovies(), [`sirat-${run}`]);

  const { status, body } = await read(CINEMA, "instagram", [
    movie("outro", newTmdbId()),
    identifiedByVideo("filme", sourceTitle, tmdbId),
  ], [
    session("outro", `${day}T17:00`),
    session("filme", `${day}T19:00`),
    session("filme", `${day}T21:00`),
  ], at(day, "09:00"));

  assertEquals(status, 200, JSON.stringify(body));
  assertEquals(body.result, "success");
  assertEquals(body.sessions, { received: 3, discarded: 0, accepted: 3, retained: 0 });
  assertEquals(alertsOf("pending-identification", body.alerts), []);
  assertEquals(alertsOf("movie-without-tmdb", body.alerts), []);
  assertEquals(alertsOf("movie-identified-by-video", body.alerts), [
    {
      type: "movie-identified-by-video",
      subject: `movie-identified-by-video:${CINEMA}:${normalized}`,
      effect: "inform",
      text: `Cinema do Centro: o título na fonte "${sourceTitle}" foi identificado pelo vídeo ` +
        `do filme como Filme ${tmdbId} (2025), TMDB ${tmdbId}, com 2 sessões aceitas. Confira a ` +
        "troca e, se estiver errada, corrija o título na fonte resolvido no banco e recolete o " +
        "cinema.\n" +
        `Filme escolhido: https://www.themoviedb.org/movie/${tmdbId}\n` +
        `Vídeo do filme: ${VIDEO_POST}`,
    },
  ]);

  // The movie without TMDB of the same source title loses the cinema's
  // sessions to the TMDB movie, with the TMDB data.
  const shown = await showtimeMovies();
  assertEquals(shown.filter((slug) => slug === `movie-${tmdbId}`).length, 2);
  assertEquals(shown.includes(`sirat-${run}`), false);
  const [chosen] = await readView("site_movies", `slug=eq.movie-${tmdbId}`);
  assertEquals([chosen.tmdb_id, chosen.title, chosen.year], [tmdbId, `Filme ${tmdbId}`, 2025]);

  assertEquals(
    (await resolvedSourceTitles(at(day, "09:30"))).filter((resolved) =>
      resolved.source_title === sourceTitle
    ),
    [{ source_title: sourceTitle, tmdb_id: tmdbId }],
  );
});

Deno.test("a leitura seguinte usa o título na fonte resolvido pelo vídeo do filme, sem abrir os vídeos nem alertar de novo", async () => {
  const day = newWeek();
  const sourceTitle = `Valor Sentimental ${run}`;
  const tmdbId = newTmdbId();

  const identified = await read(
    CINEMA,
    "instagram",
    [
      identifiedByVideo("filme", sourceTitle, tmdbId),
    ],
    [session("filme", `${day}T19:00`)],
    at(day, "08:00"),
  );
  assertEquals(identified.body.result, "success", JSON.stringify(identified.body));
  assertEquals(alertsOf("movie-identified-by-video", identified.body.alerts).length, 1);

  // The Hermes sends the source title as it is, without the video, and the
  // resolution takes it to the chosen movie.
  const next = await read(CINEMA, "instagram", [withoutTmdb("filme", sourceTitle)], [
    session("filme", `${day}T19:00`),
    session("filme", `${day}T21:00`),
  ], at(day, "09:00"));
  assertEquals(next.body.result, "success", JSON.stringify(next.body));
  assertEquals(next.body.sessions, { received: 2, discarded: 0, accepted: 2, retained: 0 });
  assertEquals(alertsOf("movie-identified-by-video", next.body.alerts), []);
  assertEquals(alertsOf("movie-without-tmdb", next.body.alerts), []);
  assertEquals(await showtimeMovies(), [`movie-${tmdbId}`, `movie-${tmdbId}`]);

  // A reading without a new post reuses the post with the video block and
  // does not inform it again.
  const reused = await read(CINEMA, "instagram", [], [], at(day, "10:00"), {
    no_new_post: true,
  });
  assertEquals(reused.body.result, "success", JSON.stringify(reused.body));
  assertEquals(alertsOf("movie-identified-by-video", reused.body.alerts), []);
  assertEquals(await showtimeMovies(), [`movie-${tmdbId}`, `movie-${tmdbId}`]);
});

Deno.test("a proposta pelo vídeo do filme que não coincide com o primeiro resultado da busca pelo título original vira identificação pendente, sem título na fonte resolvido", async () => {
  const day = newWeek();
  const sourceTitle = `O Agente Secreto ${run}`;
  const tmdbId = newTmdbId();
  const videoTopId = newTmdbId();
  const other = newTmdbId();

  const { status, body } = await read(CINEMA, "instagram", [
    movie("outro", other),
    identifiedByVideo("filme", sourceTitle, tmdbId, videoTopId),
  ], [
    session("outro", `${day}T17:00`),
    session("filme", `${day}T19:00`),
  ], at(day, "08:00"));

  assertEquals(status, 200, JSON.stringify(body));
  assertEquals(body.result, "success");
  assertEquals(body.sessions, { received: 2, discarded: 0, accepted: 1, retained: 1 });
  assertEquals(alertsOf("movie-identified-by-video", body.alerts), []);
  assertEquals(alertsOf("pending-identification", body.alerts), [
    {
      type: "pending-identification",
      subject: `pending-identification:${CINEMA}:o agente secreto ${run}`,
      effect: "open",
      text: `Cinema do Centro: o título na fonte "${sourceTitle}" ficou em identificação ` +
        `pendente, com 1 sessão retida. O filme proposto é Filme ${tmdbId} (2025), TMDB ` +
        `${tmdbId}, mas a busca pelo título na fonte e pelo ano não trouxe resultado. O filme ` +
        `foi proposto pelo vídeo do filme, com o título original "Movie ${tmdbId}" e a direção ` +
        "de Diretora Um, Diretor Dois, mas o primeiro resultado da busca por esse título é o " +
        `TMDB ${videoTopId}. Aceite o filme proposto ou escolha outro para liberar as sessões.\n` +
        `Filme proposto: https://www.themoviedb.org/movie/${tmdbId}\n` +
        `Vídeo do filme: ${VIDEO_POST}\n` +
        `Primeiro resultado pelo vídeo: https://www.themoviedb.org/movie/${videoTopId}`,
      proposed_movie: { tmdb_id: tmdbId, title: `Filme ${tmdbId}`, year: 2025 },
    },
  ]);
  assertEquals(await showtimeMovies(), [`movie-${other}`]);
  assertEquals(
    (await resolvedSourceTitles(at(day, "08:30"))).filter((resolved) =>
      resolved.source_title === sourceTitle
    ),
    [],
  );
});

Deno.test("o bloco video_identification incompleto, num filme sem TMDB ou fora de uma leitura do Instagram é erro de contrato", async () => {
  const day = newWeek();
  const complete = videoIdentification(9700001);
  const cases: [string, string, Record<string, unknown>, string[]][] = [
    ["sem o link do post", "instagram", {
      video_identification: { ...complete, post_url: undefined },
    }, [
      "/reading/movies/0/video_identification/post_url",
    ]],
    [
      "sem o título original",
      "instagram",
      { video_identification: { ...complete, original_title: undefined } },
      ["/reading/movies/0/video_identification/original_title"],
    ],
    [
      "sem a direção",
      "instagram",
      { video_identification: { ...complete, directors: undefined } },
      [
        "/reading/movies/0/video_identification/directors",
      ],
    ],
    ["com a direção vazia", "instagram", { video_identification: { ...complete, directors: [] } }, [
      "/reading/movies/0/video_identification/directors",
    ]],
    [
      "sem o primeiro resultado da busca",
      "instagram",
      { video_identification: { ...complete, tmdb_search_top_id: undefined } },
      ["/reading/movies/0/video_identification/tmdb_search_top_id"],
    ],
    [
      "num filme sem TMDB",
      "instagram",
      {
        tmdb_id: null,
        tmdb_title: undefined,
        tmdb_year: undefined,
        tmdb: undefined,
        without_tmdb: { title: `Filme do vídeo ${run}` },
      },
      ["/reading/movies/0/video_identification"],
    ],
    ["numa leitura do ingresso.com", "ingresso_com", {}, [
      "/reading/movies/0/video_identification",
    ]],
  ];

  for (const [name, source, change, paths] of cases) {
    const entry = { ...identifiedByVideo("filme", `Filme do vídeo ${run}`, 9700001), ...change };
    const response = await callIngestion("record-reading", {
      reading_id: crypto.randomUUID(),
      collection_release: "v0.1.0",
      reading: {
        cinema: source === "instagram" ? CINEMA : "cinemark-jardins",
        source,
        status: "ok",
        movies: [JSON.parse(JSON.stringify(entry))],
        sessions: [session("filme", `${day}T19:00`)],
        ...(source === "instagram" ? { post: post() } : {}),
      },
    });
    assertEquals(response.status, 400, name);
    assertEquals(response.body.error.code, "invalid_request", name);
    assertEquals(response.body.error.issues.map((issue: any) => issue.path), paths, name);
  }
});
