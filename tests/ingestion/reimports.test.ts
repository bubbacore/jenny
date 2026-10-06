// deno-lint-ignore-file no-explicit-any
import { assert, assertEquals } from "@std/assert";
import { callIngestion, readView } from "./local.ts";
import { at, movie, newTmdbId as newId, newWeek, read, session } from "./reading.ts";

const PLANNED_AT = "2026-10-12T07:00:00-03:00";
const REIMPORTED_AT = "2026-10-12T07:10:00-03:00";

// A 1x1 PNG.
const PNG =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";

// Records a new image and returns its path in TMDB.
async function newImage(): Promise<string> {
  const tmdbPath = `/i${newId()}.png`;
  const { status, body } = await callIngestion("record-image", {
    tmdb_path: tmdbPath,
    content: PNG,
  });
  assertEquals(status, 200, JSON.stringify(body));
  return tmdbPath;
}

function person(tmdbId: number, name: string, photoPath?: string) {
  return { tmdb_id: tmdbId, name, ...(photoPath ? { photo_path: photoPath } : {}) };
}

function trailer(key: string) {
  return {
    site: "YouTube",
    key,
    language: "pt",
    version: "dubbed",
    official: true,
    published_at: "2026-09-01T12:00:00.000Z",
  };
}

// Reads the movies in a cinema, in a week of their own, with one accepted
// session each. A movie without TMDB data enters with only the titles.
async function readMovies(movies: any[]) {
  const monday = newWeek();
  const response = await read(
    "cine-alquimia",
    "ingresso_com",
    movies,
    movies.map((entry, index) => session(entry.key, `${monday}T${14 + index}:00`)),
    at(monday, "12:00"),
  );
  assertEquals(response.body.result, "success", JSON.stringify(response.body));
}

function plan(body: unknown, clock = PLANNED_AT) {
  return callIngestion("reimport-plan", body, { clock });
}

// Starts a manual reimport of the chosen movies and people and returns its
// id.
async function manualPlan(movies?: number[], people?: number[]): Promise<string> {
  const { status, body } = await plan({
    type: "manual",
    ...(movies ? { movies } : {}),
    ...(people ? { people } : {}),
  });
  assertEquals(status, 200, JSON.stringify(body));
  return body.reimport_id;
}

function reimport(
  reimportId: string,
  movies: unknown[],
  people: unknown[] = [],
  clock = REIMPORTED_AT,
) {
  return callIngestion("reimport", { reimport_id: reimportId, movies, people }, { clock });
}

async function siteMovie(tmdbId: number): Promise<any> {
  const [found] = await readView("site_movies", `tmdb_id=eq.${tmdbId}`);
  return found;
}

async function storedMovie(tmdbId: number, columns: string): Promise<any> {
  const [found] = await readView("movies", `select=${columns}&tmdb_id=eq.${tmdbId}`);
  return found;
}

async function storedPerson(tmdbId: number): Promise<any> {
  const [found] = await readView(
    "people",
    `select=name,photo_path,imported_at,reimported_at&tmdb_id=eq.${tmdbId}`,
  );
  return found;
}

async function losses(reimportId: string): Promise<string[]> {
  const found = await readView(
    "reimport_losses",
    `select=field,new_loss,credit_type&reimport_id=eq.${reimportId}&order=id`,
  );
  return found.map((loss) =>
    [loss.field, loss.credit_type, loss.new_loss ? "new" : "known"].filter(Boolean).join(" ")
  );
}

// A movie in the catalog with everything TMDB can give.
async function fullMovie() {
  const id = newId();
  const poster = await newImage();
  const actress = newId();
  const actor = newId();
  const director = newId();
  const actressPhoto = await newImage();
  const tmdb = {
    title: "Ainda Estou Aqui",
    original_title: "Ainda Estou Aqui",
    imdb_id: "tt14961016",
    overview: "Uma família enfrenta a ditadura.",
    year: 2024,
    countries: ["BR"],
    original_language: "pt",
    genres: [{ tmdb_id: 18, name: "Drama", english_name: "Drama" }],
    runtime: 136,
    budget: 1_500_000,
    revenue: 30_000_000,
    content_rating: "14",
    poster_path: poster,
    trailers: [trailer(`yt-${id}`)],
    credits: {
      cast: [
        { person: person(actress, "Fernanda Torres", actressPhoto), character: "Eunice", order: 0 },
        { person: person(actor, "Selton Mello"), character: "Rubens", order: 1 },
      ],
      directors: [{ person: person(director, "Walter Salles") }],
    },
  };
  await readMovies([movie("a", id, { tmdb })]);
  return { id, tmdb, poster, actress, actor, director, actressPhoto };
}

Deno.test("o plano semanal cobre os filmes em exibição, com os identificadores, os títulos e o ano", async () => {
  const showing = newId();
  const gone = newId();
  const monday = newWeek();
  for (const [key, id] of [["a", gone], ["b", showing]] as const) {
    const response = await read(
      "cine-alquimia",
      "ingresso_com",
      [movie(key, id, {
        tmdb: { title: `Filme ${id}`, original_title: `Movie ${id}`, year: 2026 },
      })],
      [session(key, `${monday}T20:00`)],
      at(monday, key === "a" ? "08:00" : "10:00"),
    );
    assertEquals(response.body.result, "success", JSON.stringify(response.body));
  }

  const { status, body } = await plan({ type: "weekly" });

  assertEquals(status, 200, JSON.stringify(body));
  assert(typeof body.reimport_id === "string");
  assertEquals(body.people, []);
  assertEquals(body.movies.filter((planned: any) => [showing, gone].includes(planned.tmdb_id)), [
    {
      tmdb_id: showing,
      imdb_id: null,
      title: `Filme ${showing}`,
      original_title: `Movie ${showing}`,
      year: 2026,
    },
  ]);
});

Deno.test("o plano manual cobre os filmes e as pessoas escolhidos, inclusive fora de exibição, ou todo o acervo", async () => {
  const { id, actor } = await fullMovie();
  await readMovies([movie("b", newId())]);

  const chosen = await plan({ type: "manual", movies: [id], people: [actor] });
  assertEquals(chosen.status, 200, JSON.stringify(chosen.body));
  assertEquals(chosen.body.movies.map((planned: any) => planned.tmdb_id), [id]);
  assertEquals(chosen.body.people, [{ tmdb_id: actor, name: "Selton Mello" }]);

  const whole = await plan({ type: "manual" });
  assertEquals(whole.status, 200, JSON.stringify(whole.body));
  assert(whole.body.movies.some((planned: any) => planned.tmdb_id === id));
  assertEquals(whole.body.people, []);
});

Deno.test("o plano recusa filmes e pessoas fora do acervo e escolhas na rodada semanal", async () => {
  const { id } = await fullMovie();

  const unknown = await plan({ type: "manual", movies: [id, newId()], people: [newId()] });
  assertEquals(unknown.status, 400);
  assertEquals(unknown.body.error.code, "unknown_catalog_item");
  assertEquals(unknown.body.error.issues.map((issue: any) => issue.path), [
    "/movies/1",
    "/people/0",
  ]);

  const weekly = await plan({ type: "weekly", movies: [id] });
  assertEquals(weekly.status, 400);
  assertEquals(weekly.body.error.code, "invalid_request");
  assertEquals(weekly.body.error.issues.map((issue: any) => issue.path), ["/movies"]);
});

Deno.test("a reimportação atualiza os dados, os créditos e as imagens que mudaram", async () => {
  const { id, tmdb, actress, actor, director } = await fullMovie();
  const newPoster = await newImage();
  const newPhoto = await newImage();
  const newcomer = newId();
  const { slug } = await siteMovie(id);
  const reimportId = await manualPlan([id]);

  const { status, body } = await reimport(reimportId, [{
    tmdb_id: id,
    tmdb: {
      ...tmdb,
      title: "Ainda Estou Aqui (versão nova)",
      overview: "Uma mãe enfrenta a ditadura.",
      genres: [
        { tmdb_id: 36, name: "História", english_name: "History" },
        { tmdb_id: 18, name: "Drama", english_name: "Drama" },
      ],
      runtime: 137,
      poster_path: newPoster,
      trailers: [trailer(`yt-${id}-novo`)],
      credits: {
        cast: [
          {
            person: person(actress, "Fernanda Torres", newPhoto),
            character: "Eunice Paiva",
            order: 0,
          },
          { person: person(newcomer, "Fernanda Montenegro"), character: "Eunice idosa", order: 1 },
          { person: person(actor, "Selton Mello"), character: "Rubens", order: 2 },
        ],
        directors: [{ person: person(director, "Walter Salles") }],
      },
    },
  }]);

  assertEquals(status, 200, JSON.stringify(body));
  assertEquals(body, { reimport_id: reimportId, movies: 1, people: 4, losses: 0, alerts: [] });

  const site = await siteMovie(id);
  assertEquals(site.title, "Ainda Estou Aqui (versão nova)");
  assertEquals(site.slug, slug);
  assertEquals(site.overview, "Uma mãe enfrenta a ditadura.");
  assertEquals(site.runtime_minutes, 137);
  assertEquals(site.poster, newPoster.slice(1));
  assertEquals(site.trailer, { youtube_key: `yt-${id}-novo`, version: "original" });
  assertEquals(site.genres, [{ slug: "history", name: "História" }, {
    slug: "drama",
    name: "Drama",
  }]);
  assertEquals(
    site.cast.map((credit: any) => [credit.name, credit.character, credit.photo]),
    [
      ["Fernanda Torres", "Eunice Paiva", newPhoto.slice(1)],
      ["Fernanda Montenegro", "Eunice idosa", null],
      ["Selton Mello", "Rubens", null],
    ],
  );
  assertEquals(
    (await storedMovie(id, "metadata_updated_at")).metadata_updated_at,
    "2026-10-12T10:10:00+00:00",
  );
  assertEquals((await storedPerson(actress)).reimported_at, "2026-10-12T10:10:00+00:00");
  assertEquals(await storedPerson(newcomer), {
    name: "Fernanda Montenegro",
    photo_path: null,
    imported_at: "2026-10-12T10:10:00+00:00",
    reimported_at: null,
  });

  const [recorded] = await readView(
    "reimports",
    `select=type,started_at,finished_at&id=eq.${reimportId}`,
  );
  assertEquals(recorded, {
    type: "manual",
    started_at: "2026-10-12T10:00:00+00:00",
    finished_at: "2026-10-12T10:10:00+00:00",
  });
});

Deno.test("quem sai dos cinco primeiros do elenco, mas continua no TMDB, perde o crédito sem perda registrada", async () => {
  const id = newId();
  const cast = [0, 1, 2, 3, 4].map((order) => ({
    person: person(newId(), `Pessoa ${order}`),
    order,
  }));
  const credits = { cast, directors: [] };
  await readMovies([
    movie("a", id, { tmdb: { title: "Filme", original_title: "Movie", credits } }),
  ]);
  const reimportId = await manualPlan([id]);

  const { body } = await reimport(reimportId, [{
    tmdb_id: id,
    tmdb: {
      title: "Filme",
      original_title: "Movie",
      credits: {
        cast: [
          { person: person(newId(), "Pessoa nova"), order: 0 },
          ...cast.map((credit) => ({
            ...credit,
            order: credit.order + 1,
          })),
        ],
        directors: [],
      },
    },
  }]);

  assertEquals(body.losses, 0, JSON.stringify(body));
  assertEquals((await siteMovie(id)).cast.map((credit: any) => credit.name), [
    "Pessoa nova",
    "Pessoa 0",
    "Pessoa 1",
    "Pessoa 2",
    "Pessoa 3",
  ]);
});

Deno.test("o que sumiu do TMDB é mantido no acervo, registrado na reimportação e alertado com tmdb-loss", async () => {
  const { id, tmdb, poster, actress, actor, actressPhoto } = await fullMovie();
  const reimportId = await manualPlan([id]);
  const { overview: _overview, poster_path: _poster, budget: _budget, ...kept } = tmdb;

  const { status, body } = await reimport(reimportId, [{
    tmdb_id: id,
    tmdb: {
      ...kept,
      revenue: 0,
      credits: {
        cast: [{ person: person(actress, "Fernanda Torres"), order: 0 }],
        directors: tmdb.credits.directors,
      },
    },
  }]);

  assertEquals(status, 200, JSON.stringify(body));
  assertEquals(body.losses, 7);
  assertEquals(body.alerts, [{
    type: "tmdb-loss",
    subject: "tmdb-loss",
    effect: "open",
    text:
      "Reimportação manual: o TMDB não tem mais o que segue, e o acervo manteve o que tinha.\n" +
      "- Ainda Estou Aqui (2024): a sinopse, o orçamento, a receita, o pôster, " +
      "o crédito de Selton Mello no elenco, o personagem de Fernanda Torres\n" +
      "- Fernanda Torres: a foto",
  }]);
  assertEquals(await losses(reimportId), [
    "overview new",
    "budget new",
    "revenue new",
    "poster_path new",
    "credit cast new",
    "photo_path new",
    "character cast new",
  ]);

  const site = await siteMovie(id);
  assertEquals(site.overview, "Uma família enfrenta a ditadura.");
  assertEquals(site.poster, poster.slice(1));
  assertEquals(
    site.cast.map((credit: any) => [credit.tmdb_id, credit.character, credit.photo]),
    [[actress, "Eunice", actressPhoto.slice(1)], [actor, "Rubens", null]],
  );
  assertEquals(await storedMovie(id, "budget_usd,revenue_usd"), {
    budget_usd: 1_500_000,
    revenue_usd: 30_000_000,
  });
});

Deno.test("sem perdas, a reimportação não gera alerta", async () => {
  const { id, tmdb } = await fullMovie();
  const reimportId = await manualPlan([id]);

  const { status, body } = await reimport(reimportId, [{ tmdb_id: id, tmdb }]);

  assertEquals(status, 200, JSON.stringify(body));
  assertEquals(body.losses, 0);
  assertEquals(body.alerts, []);
});

Deno.test("uma perda já registrada na reimportação anterior do mesmo filme fica fora do alerta", async () => {
  const { id, tmdb } = await fullMovie();
  const { overview: _overview, ...withoutOverview } = tmdb;

  const first = await reimport(await manualPlan([id]), [{ tmdb_id: id, tmdb: withoutOverview }]);
  assertEquals(first.body.alerts.length, 1, JSON.stringify(first.body));

  const secondId = await manualPlan([id]);
  const second = await reimport(
    secondId,
    [{ tmdb_id: id, tmdb: { ...withoutOverview, runtime: undefined } }],
    [],
    "2026-10-12T07:20:00-03:00",
  );
  assertEquals(second.status, 200, JSON.stringify(second.body));
  assertEquals(await losses(secondId), ["overview known", "runtime new"]);
  assertEquals(
    second.body.alerts[0].text,
    "Reimportação manual: o TMDB não tem mais o que segue, e o acervo manteve o que tinha.\n" +
      "- Ainda Estou Aqui (2024): a duração",
  );

  const thirdId = await manualPlan([id]);
  const third = await reimport(
    thirdId,
    [{ tmdb_id: id, tmdb: { ...withoutOverview, runtime: undefined } }],
    [],
    "2026-10-12T07:30:00-03:00",
  );
  assertEquals(await losses(thirdId), ["overview known", "runtime known"]);
  assertEquals(third.body.alerts, []);
});

Deno.test("a reimportação traz a classificação indicativa do TMDB e escolhe de novo o valor do filme", async () => {
  const id = newId();
  await readMovies([movie("a", id, { content_rating: "12" })]);
  assertEquals(
    await storedMovie(id, "content_rating,content_rating_source_type"),
    { content_rating: "12", content_rating_source_type: "ingresso_com" },
  );
  const reimportId = await manualPlan([id]);

  const { body } = await reimport(reimportId, [{
    tmdb_id: id,
    tmdb: { title: `Filme ${id}`, original_title: `Movie ${id}`, content_rating: "16" },
  }]);

  assertEquals(body.alerts, [], JSON.stringify(body));
  assertEquals(
    await storedMovie(id, "content_rating,content_rating_source_type,tmdb_content_rating"),
    { content_rating: "16", content_rating_source_type: null, tmdb_content_rating: "16" },
  );
  assertEquals((await siteMovie(id)).content_rating, "16");
});

Deno.test("a rodada manual reimporta pessoas escolhidas e mantém o filme e a pessoa que o TMDB não tem mais", async () => {
  const { id, actor, actress, actressPhoto } = await fullMovie();
  const photo = await newImage();
  const reimportId = await manualPlan([id], [actor, actress]);

  const { status, body } = await reimport(
    reimportId,
    [{ tmdb_id: id, tmdb: null }],
    [
      { tmdb_id: actor, tmdb: { name: "Selton Mello", photo_path: photo } },
      { tmdb_id: actress, tmdb: null },
    ],
  );

  assertEquals(status, 200, JSON.stringify(body));
  assertEquals(
    body.alerts[0].text,
    "Reimportação manual: o TMDB não tem mais o que segue, e o acervo manteve o que tinha.\n" +
      "- Ainda Estou Aqui (2024): o filme, que não está mais no TMDB\n" +
      "- Fernanda Torres: a pessoa, que não está mais no TMDB",
  );
  assertEquals((await storedPerson(actor)).photo_path, photo);
  assertEquals((await storedPerson(actress)).photo_path, actressPhoto);
  assertEquals((await siteMovie(id)).overview, "Uma família enfrenta a ditadura.");
});

Deno.test("a reimportação recusa itens fora do plano e imagens não gravadas", async () => {
  const { id, tmdb, actor } = await fullMovie();
  const reimportId = await manualPlan([id]);

  const { status, body } = await reimport(
    reimportId,
    [
      { tmdb_id: id, tmdb: { ...tmdb, poster_path: `/nao-gravada-${id}.jpg` } },
      { tmdb_id: newId(), tmdb: null },
    ],
    [{ tmdb_id: actor, tmdb: { name: "Selton Mello", photo_path: `/nao-gravada-${id}-foto.jpg` } }],
  );

  assertEquals(status, 400);
  assertEquals(body.error.code, "invalid_reimport");
  assertEquals(body.error.issues.map((issue: any) => issue.path), [
    "/movies/1/tmdb_id",
    "/people/0/tmdb_id",
    "/movies/0/tmdb/poster_path",
    "/people/0/tmdb/photo_path",
  ]);
  assertEquals(await losses(reimportId), []);
});

Deno.test("uma reimportação terminada ou desconhecida é recusada", async () => {
  const { id, tmdb } = await fullMovie();
  const reimportId = await manualPlan([id]);
  assertEquals((await reimport(reimportId, [{ tmdb_id: id, tmdb }])).status, 200);

  const again = await reimport(reimportId, [{ tmdb_id: id, tmdb }]);
  assertEquals(again.status, 409);
  assertEquals(again.body.error.code, "reimport_closed");

  const unknown = await reimport(crypto.randomUUID(), []);
  assertEquals(unknown.status, 400);
  assertEquals(unknown.body.error.code, "unknown_reimport");
});
