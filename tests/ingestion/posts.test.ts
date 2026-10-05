// deno-lint-ignore-file no-explicit-any
import { assertEquals } from "@std/assert";
import { callIngestion, readView } from "./local.ts";
import {
  addDays,
  at,
  cinemaDays,
  movie,
  newTmdbId,
  newWeek,
  post,
  read,
  reading,
  record,
  RELEASE,
  session,
  showtimes,
  start,
  window,
} from "./reading.ts";

// The Cinema do Centro is read in the weekly post on its official site, and it
// is closed on Tuesdays and Wednesdays.
const CINEMA = "cinema-do-centro";

// A source title new to every run, so its pending identification is new.
const run = crypto.randomUUID().slice(0, 8);

function readPost(
  weeklyPost: ReturnType<typeof post>,
  movies: unknown[],
  sessions: unknown[],
  clock: string,
) {
  return read(CINEMA, "official_site", movies, sessions, clock, { post: weeklyPost });
}

function readWithoutNewPost(clock: string) {
  return read(CINEMA, "official_site", [], [], clock, { no_new_post: true });
}

async function lastReadPosts(clock: string): Promise<Record<string, any>> {
  const { status, body } = await callIngestion("collection-plan", {
    collection_type: "manual",
    cinemas: [CINEMA, "cinemark-riomar"],
  }, { clock });
  assertEquals(status, 200, JSON.stringify(body));
  return Object.fromEntries(body.cinemas.map((cinema: any) => [
    cinema.slug,
    cinema.last_read_post &&
    { ...cinema.last_read_post, published_at: iso(cinema.last_read_post.published_at) },
  ]));
}

function iso(time: string): string {
  return new Date(time).toISOString();
}

function lastPost(weeklyPost: ReturnType<typeof post>) {
  return {
    source: "official_site",
    url: weeklyPost.url,
    published_at: iso(weeklyPost.published_at),
  };
}

async function history(readingId: string) {
  const [row] = await readView(
    "readings",
    `id=eq.${readingId}&select=status,post_url,post_published_at,no_new_post,reused_reading_id`,
  );
  return { ...row, post_published_at: row.post_published_at && iso(row.post_published_at) };
}

Deno.test("o plano devolve o último post lido de cada cinema, com a fonte, o link e a data", async () => {
  const day = newWeek();
  const thursday = addDays(day, 3);
  const first = post(at(addDays(day, -5), "10:00"));
  const second = post(at(day, "11:30"));

  await readPost(
    first,
    [movie("a", 9400101)],
    [session("a", `${thursday}T18:00`)],
    at(day, "08:00"),
  );
  assertEquals(await lastReadPosts(at(day, "09:00")), {
    [CINEMA]: lastPost(first),
    "cinemark-riomar": null,
  });

  const reused = await readWithoutNewPost(at(day, "10:00"));
  assertEquals(reused.body.result, "success", JSON.stringify(reused.body));
  assertEquals((await lastReadPosts(at(day, "11:00")))[CINEMA], lastPost(first));

  await readPost(
    second,
    [movie("a", 9400101)],
    [session("a", `${thursday}T20:00`)],
    at(day, "12:00"),
  );
  assertEquals((await lastReadPosts(at(day, "13:00")))[CINEMA], lastPost(second));
  assertEquals((await lastReadPosts(at(day, "11:00")))[CINEMA], lastPost(first));
});

Deno.test("uma leitura sem post novo reaproveita a programação do último post lido e tem sucesso enquanto houver sessões de hoje em diante", async () => {
  const day = newWeek();
  const [, tuesday, , thursday, friday] = window(day);
  const weeklyPost = post(at(addDays(day, -5), "10:00"));

  const postReading = await readPost(weeklyPost, [movie("a", 9400111), movie("b", 9400112)], [
    session("a", `${day}T19:00`),
    session("a", `${thursday}T18:00`),
    session("b", `${friday}T20:00`),
  ], at(day, "08:00"));
  assertEquals(postReading.body.sessions.accepted, 3);

  const { status, body } = await readWithoutNewPost(at(tuesday, "08:00"));
  assertEquals(status, 200, JSON.stringify(body));
  assertEquals(body.result, "success");
  assertEquals(body.sessions, { received: 3, discarded: 1, accepted: 2, retained: 0 });
  assertEquals(body.alerts, []);
  assertEquals((await showtimes(CINEMA)).map((row) => [row.movie, row.date]), [
    ["movie-9400111", thursday],
    ["movie-9400112", friday],
  ]);

  assertEquals(await history(postReading.body.reading_id), {
    status: "success",
    post_url: weeklyPost.url,
    post_published_at: iso(weeklyPost.published_at),
    no_new_post: false,
    reused_reading_id: null,
  });
  assertEquals(await history(body.reading_id), {
    status: "success",
    post_url: null,
    post_published_at: null,
    no_new_post: true,
    reused_reading_id: postReading.body.reading_id,
  });
});

Deno.test("a programação reaproveitada sem nenhuma sessão de hoje em diante num dia de funcionamento é leitura desatualizada e é apagada", async () => {
  const day = newWeek();
  const [, , , thursday, friday, saturday] = window(day);

  await readPost(post(at(addDays(day, -5), "10:00")), [movie("a", 9400121)], [
    session("a", `${thursday}T18:00`),
    session("a", `${friday}T18:00`),
  ], at(day, "08:00"));

  const lastDay = await readWithoutNewPost(at(friday, "08:00"));
  assertEquals(lastDay.body.result, "success");
  assertEquals(lastDay.body.sessions.accepted, 1);

  const { status, body } = await readWithoutNewPost(at(saturday, "08:00"));
  assertEquals(status, 200, JSON.stringify(body));
  assertEquals(body.result, "failure");
  assertEquals(body.failure_type, "outdated");
  assertEquals(
    body.reason,
    "A programação do último post lido não tem mais nenhuma sessão de hoje em diante, " +
      "e o cinema funciona em algum dia da janela.",
  );
  assertEquals(body.sessions, { received: 2, discarded: 2, accepted: 0, retained: 0 });
  assertEquals(body.alerts.map((alert: any) => [alert.subject, alert.effect]), [
    [`collection-failure:${CINEMA}`, "open"],
  ]);
  assertEquals(await showtimes(CINEMA), []);
  assertEquals(
    await cinemaDays(CINEMA, at(saturday, "08:00")),
    window(saturday).map((date) => [date, "updating"]),
  );
});

Deno.test("a programação reaproveitada segue as resoluções feitas depois da leitura do post", async () => {
  const day = newWeek();
  const thursday = addDays(day, 3);
  const title = `Filme b ${run}`;

  const postReading = await readPost(post(), [
    movie("a", 9400131),
    movie("b", 9400132, { source_title: title, tmdb_search_top_id: 9400133 }),
  ], [
    session("a", `${thursday}T18:00`),
    session("b", `${thursday}T20:00`),
  ], at(day, "08:00"));
  assertEquals(postReading.body.sessions.retained, 1);

  const resolved = await callIngestion("resolve-pending-identification", {
    cinema: CINEMA,
    source_title: title,
    tmdb_id: 9400132,
  }, { clock: at(day, "09:00") });
  assertEquals(resolved.status, 200, JSON.stringify(resolved.body));

  const { body } = await readWithoutNewPost(at(day, "10:00"));
  assertEquals(body.result, "success");
  assertEquals(body.sessions, { received: 2, discarded: 0, accepted: 2, retained: 0 });
  assertEquals((await showtimes(CINEMA)).map((row) => row.movie), [
    "movie-9400131",
    "movie-9400132",
  ]);
});

// Records a reading without a new post that the ingestion refuses, and then
// closes its reservation with an error, so it does not hold the cinema.
async function refusedWithoutNewPost(clock: string) {
  const started = await start(CINEMA, clock);
  assertEquals(started.status, 201, JSON.stringify(started.body));
  const refused = await record(
    started.body.reading_id,
    reading(CINEMA, "official_site", [], [], { no_new_post: true }),
    clock,
  );
  const closed = await record(
    started.body.reading_id,
    reading(CINEMA, "official_site", [], [], { status: "error", reason: "Leitura recusada." }),
    clock,
  );
  assertEquals(closed.status, 200, JSON.stringify(closed.body));
  return refused;
}

Deno.test("uma leitura sem post novo é recusada quando não há programação de post para reaproveitar", async () => {
  const beforeEveryPost = await refusedWithoutNewPost("2025-01-06T12:00:00-03:00");
  assertEquals(beforeEveryPost.status, 400);
  assertEquals(beforeEveryPost.body.error.code, "invalid_reading");
  assertEquals(beforeEveryPost.body.error.issues, [{
    path: "/reading/no_new_post",
    message: "O cinema não tem post lido para reaproveitar. Leia o post mais recente.",
  }]);

  // A resolution chose a movie outside the catalog after the post was read,
  // and the showtimes of the post do not bring it.
  const day = newWeek();
  const title = `Filme c ${run}`;
  const weeklyPost = post();
  await readPost(
    weeklyPost,
    [
      movie("c", 9400141, { source_title: title, tmdb_search_top_id: 9400142 }),
    ],
    [session("c", `${addDays(day, 3)}T20:00`)],
    at(day, "08:00"),
  );
  await callIngestion("resolve-pending-identification", {
    cinema: CINEMA,
    source_title: title,
    tmdb_id: newTmdbId(),
  }, { clock: at(day, "09:00") });

  const { status, body } = await refusedWithoutNewPost(at(day, "10:00"));
  assertEquals(status, 400);
  assertEquals(body.error.code, "invalid_reading");
  assertEquals(body.error.issues, [{
    path: "/reading/no_new_post",
    message: `A programação do último post lido, em ${weeklyPost.url}, tem um filme que ainda ` +
      "não está no acervo e que ela não traz completo. Leia o post de novo.",
  }]);
});

Deno.test("uma leitura de post sem a fonte, o link ou a data, ou sem post novo com filmes ou sessões, é erro de contrato", async () => {
  const valid = () => ({
    reading_id: crypto.randomUUID(),
    collection_release: RELEASE,
    reading: reading(CINEMA, "official_site", [movie("a", 9400151)], [
      session("a", "2026-10-08T19:00"),
    ]),
  });
  const cases: [string, (body: any) => void, string[]][] = [
    ["sem a fonte", (b) => delete b.reading.source, ["/reading/source"]],
    ["sem o post", (b) => delete b.reading.post, ["/reading/post"]],
    ["post sem o link", (b) => delete b.reading.post.url, ["/reading/post/url"]],
    ["post sem a data", (b) => delete b.reading.post.published_at, ["/reading/post/published_at"]],
    ["data do post sem fuso", (b) => b.reading.post.published_at = "2026-10-01T10:00", [
      "/reading/post/published_at",
    ]],
    ["post e sem post novo", (b) => {
      b.reading.no_new_post = true;
      b.reading.movies = [];
      b.reading.sessions = [];
    }, ["/reading/no_new_post"]],
    ["sem post novo com filmes e sessões", (b) => {
      delete b.reading.post;
      b.reading.no_new_post = true;
    }, ["/reading/movies", "/reading/sessions"]],
    ["sem post novo com filmes", (b) => {
      delete b.reading.post;
      b.reading.no_new_post = true;
      b.reading.sessions = [];
    }, ["/reading/movies"]],
    ["post numa leitura com erro", (b) => {
      b.reading.status = "error";
      b.reading.reason = "O site não respondeu.";
    }, ["/reading/post"]],
    ["post numa leitura de outra fonte", (b) => {
      b.reading.cinema = "cine-alquimia";
      b.reading.source = "ingresso_com";
    }, ["/reading/post"]],
    ["sem post novo numa leitura de outra fonte", (b) => {
      b.reading = reading("cine-alquimia", "ingresso_com", [], [], { no_new_post: true });
    }, ["/reading/no_new_post"]],
  ];

  for (const [name, change, paths] of cases) {
    const body = valid();
    change(body);
    const response = await callIngestion("record-reading", body);
    assertEquals(response.status, 400, name);
    assertEquals(response.body.error.code, "invalid_request", name);
    assertEquals(response.body.error.issues.map((issue: any) => issue.path), paths, name);
  }
});
