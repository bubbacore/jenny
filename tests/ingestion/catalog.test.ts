// deno-lint-ignore-file no-explicit-any
import { assert, assertEquals } from "@std/assert";
import { apiUrl, callIngestion, publishableKey, readView, secretKey } from "./local.ts";
import { at, newTmdbId as newId, newWeek, read, session } from "./reading.ts";

// A 1x1 PNG.
const PNG =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";

function recordImage(tmdbPath: string, content = PNG) {
  return callIngestion("record-image", { tmdb_path: tmdbPath, content });
}

// Records a new image and returns its path in TMDB.
async function newImage(): Promise<string> {
  const tmdbPath = `/i${newId()}.png`;
  const { status, body } = await recordImage(tmdbPath);
  assertEquals(status, 200, JSON.stringify(body));
  return tmdbPath;
}

function person(tmdbId: number, name: string, photoPath?: string) {
  return { tmdb_id: tmdbId, name, ...(photoPath ? { photo_path: photoPath } : {}) };
}

function trailer(key: string, extra: Record<string, unknown> = {}) {
  return {
    site: "YouTube",
    key,
    language: "pt",
    official: true,
    published_at: "2026-09-01T12:00:00.000Z",
    ...extra,
  };
}

function catalogMovie(key: string, tmdbId: number, tmdb: Record<string, unknown>) {
  return {
    key,
    source_title: `Filme ${key}`,
    tmdb_id: tmdbId,
    tmdb_search_top_id: tmdbId,
    tmdb: { title: `Filme ${tmdbId}`, original_title: `Movie ${tmdbId}`, ...tmdb },
  };
}

// Reads the movies in a cinema, in a week of their own, with one accepted
// session each, and checks that the reading succeeded.
async function readMovies(movies: any[]) {
  const monday = newWeek();
  const response = await read(
    "cine-alquimia",
    "ingresso_com",
    movies,
    movies.map((movie, index) => session(movie.key, `${monday}T${14 + index}:00`)),
    at(monday, "12:00"),
  );
  assertEquals(response.status, 200, JSON.stringify(response.body));
  assertEquals(response.body.result, "success", JSON.stringify(response.body));
  return response;
}

async function siteMovie(tmdbId: number): Promise<any> {
  const [movie] = await readView("site_movies", `tmdb_id=eq.${tmdbId}`);
  return movie;
}

function storedMovie(tmdbId: number, columns: string): Promise<any[]> {
  return readView("movies", `select=${columns}&tmdb_id=eq.${tmdbId}`);
}

Deno.test("a gravação da imagem guarda no Storage a imagem enviada, conhecida pelo caminho no TMDB", async () => {
  const tmdbPath = `/i${newId()}.png`;
  const { status, body } = await recordImage(tmdbPath);

  assertEquals(status, 200);
  assertEquals(body, {
    tmdb_path: tmdbPath,
    storage_path: tmdbPath.slice(1),
    content_type: "image/png",
    size_bytes: 70,
  });

  const stored = await fetch(`${apiUrl}/storage/v1/object/images/${body.storage_path}`, {
    headers: { apikey: secretKey, authorization: `Bearer ${secretKey}` },
  });
  assertEquals(stored.status, 200);
  assertEquals(new Uint8Array(await stored.arrayBuffer()).length, 70);

  const again = await recordImage(tmdbPath);
  assertEquals(again.status, 200);
});

Deno.test("a chave publicável não lê as imagens", async () => {
  const tmdbPath = await newImage();
  const response = await fetch(`${apiUrl}/storage/v1/object/images/${tmdbPath.slice(1)}`, {
    headers: { apikey: publishableKey },
  });
  await response.body?.cancel();
  assert(!response.ok, `a chave publicável recebeu ${response.status}`);
});

Deno.test("a gravação da imagem recusa um conteúdo que não é JPEG nem PNG", async () => {
  const { status, body } = await recordImage(`/i${newId()}.jpg`, btoa("<html></html>"));

  assertEquals(status, 400);
  assertEquals(body.error.code, "invalid_image");
  assertEquals(body.error.issues.map((issue: any) => issue.path), ["/content"]);
});

Deno.test("uma leitura que cita uma imagem não gravada é recusada", async () => {
  const id = newId();
  const monday = newWeek();
  const { status, body } = await read(
    "cine-alquimia",
    "ingresso_com",
    [
      catalogMovie("a", id, {
        poster_path: `/nao-gravada-${id}.jpg`,
        credits: {
          cast: [{ person: person(newId(), "Atriz", await newImage()), order: 0 }],
          directors: [{ person: person(newId(), "Diretor", `/nao-gravada-${id}-foto.jpg`) }],
        },
      }),
    ],
    [session("a", `${monday}T20:00`)],
    at(monday, "12:00"),
  );

  assertEquals(status, 400);
  assertEquals(body.error.code, "invalid_reading");
  assertEquals(body.error.issues.map((issue: any) => issue.path), [
    "/reading/movies/0/tmdb/poster_path",
    "/reading/movies/0/tmdb/credits/directors/0/person/photo_path",
  ]);
  assertEquals(await readView("movies", `tmdb_id=eq.${id}`), []);
});

Deno.test("um filme novo grava os metadados, os créditos e as imagens enviados na leitura", async () => {
  const id = newId();
  const poster = await newImage();
  const directorPhoto = await newImage();
  const actressPhoto = await newImage();
  const director = newId();
  const actress = newId();
  const actor = newId();

  await readMovies([
    catalogMovie("a", id, {
      imdb_id: "tt14961016",
      overview: "Uma família enfrenta a ditadura.",
      year: 2024,
      countries: ["BR", "FR"],
      original_language: "pt",
      genres: [
        { tmdb_id: 18, name: "Drama", english_name: "Drama" },
        { tmdb_id: 36, name: "História", english_name: "History" },
      ],
      runtime: 136,
      budget: 1_500_000,
      revenue: 3_000_000_000,
      content_rating: "14",
      poster_path: poster,
      trailers: [trailer(`yt-${id}`)],
      credits: {
        cast: [
          {
            person: person(actress, "Fernanda Torres", actressPhoto),
            character: "Eunice",
            order: 0,
          },
          { person: person(actor, "Selton Mello"), character: "Rubens", order: 1 },
        ],
        directors: [{ person: person(director, "Walter Salles", directorPhoto) }],
      },
    }),
  ]);

  assertEquals(await siteMovie(id), {
    slug: `movie-${id}`,
    tmdb_id: id,
    title: `Filme ${id}`,
    original_title: `Movie ${id}`,
    imdb_id: "tt14961016",
    year: 2024,
    countries: ["BR", "FR"],
    original_language: "pt",
    runtime_minutes: 136,
    overview: "Uma família enfrenta a ditadura.",
    poster: poster.slice(1),
    trailer: { youtube_key: `yt-${id}`, version: "original" },
    genres: [{ slug: "drama", name: "Drama" }, { slug: "history", name: "História" }],
    directors: [{ tmdb_id: director, name: "Walter Salles", photo: directorPhoto.slice(1) }],
    cast: [
      {
        tmdb_id: actress,
        name: "Fernanda Torres",
        character: "Eunice",
        photo: actressPhoto.slice(1),
      },
      { tmdb_id: actor, name: "Selton Mello", character: "Rubens", photo: null },
    ],
    content_rating: "14",
    imdb_rating: null,
    imdb_votes: null,
    tomatometer: null,
  });
  assertEquals(await storedMovie(id, "budget_usd,revenue_usd"), [
    { budget_usd: 1_500_000, revenue_usd: 3_000_000_000 },
  ]);
});

Deno.test("orçamento e receita zerados no TMDB ficam ausentes", async () => {
  const id = newId();
  await readMovies([catalogMovie("a", id, { budget: 0, revenue: 0 })]);

  assertEquals(await storedMovie(id, "budget_usd,revenue_usd"), [
    { budget_usd: null, revenue_usd: null },
  ]);
});

Deno.test("quem atua e dirige o mesmo filme é uma pessoa só, com dois créditos", async () => {
  const id = newId();
  const both = newId();
  const photo = await newImage();
  await readMovies([
    catalogMovie("a", id, {
      credits: {
        cast: [{ person: person(both, "Greta Gerwig", photo), character: "Ela mesma", order: 0 }],
        directors: [{ person: person(both, "Greta Gerwig", photo) }],
      },
    }),
  ]);

  const people = await readView("people", `select=id,name&tmdb_id=eq.${both}`);
  assertEquals(people.length, 1);
  const credits = await readView("credits", `select=type&person_id=eq.${people[0].id}&order=type`);
  assertEquals(credits.map((credit) => credit.type), ["cast", "director"]);

  const movie = await siteMovie(id);
  assertEquals(movie.directors.map((credit: any) => credit.tmdb_id), [both]);
  assertEquals(movie.cast.map((credit: any) => credit.tmdb_id), [both]);
});

Deno.test("uma pessoa já no acervo ganha só o crédito novo", async () => {
  const first = newId();
  const second = newId();
  const actor = newId();
  const photo = await newImage();
  await readMovies([
    catalogMovie("a", first, {
      credits: {
        cast: [{ person: person(actor, "Wagner Moura", photo), order: 0 }],
        directors: [],
      },
    }),
  ]);
  await readMovies([
    catalogMovie("b", second, {
      credits: {
        cast: [{ person: person(actor, "Outro nome", await newImage()), order: 3 }],
        directors: [],
      },
    }),
  ]);

  const people = await readView("people", `select=id,name,photo_path&tmdb_id=eq.${actor}`);
  assertEquals(people.map(({ name, photo_path }) => ({ name, photo_path })), [
    { name: "Wagner Moura", photo_path: photo },
  ]);
  const credits = await readView("credits", `select=movie_id&person_id=eq.${people[0].id}`);
  assertEquals(credits.length, 2);
});

Deno.test("o elenco guarda os cinco primeiros pela ordem do TMDB, e a direção, todos os diretores", async () => {
  const id = newId();
  const cast = [6, 2, 0, 5, 1, 4, 3].map((order) => ({
    person: person(newId(), `Pessoa ${order}`),
    order,
  }));
  await readMovies([
    catalogMovie("a", id, {
      credits: {
        cast,
        directors: [
          { person: person(newId(), "Joel Coen") },
          { person: person(newId(), "Ethan Coen") },
        ],
      },
    }),
  ]);

  const movie = await siteMovie(id);
  assertEquals(movie.cast.map((credit: any) => credit.name), [
    "Pessoa 0",
    "Pessoa 1",
    "Pessoa 2",
    "Pessoa 3",
    "Pessoa 4",
  ]);
  assertEquals(movie.directors.map((credit: any) => credit.name), ["Joel Coen", "Ethan Coen"]);
});

Deno.test("um trailer fora do YouTube é descartado", async () => {
  const id = newId();
  await readMovies([
    catalogMovie("a", id, {
      original_language: "en",
      trailers: [
        trailer("vimeo-legendado", { site: "Vimeo", version: "subtitled" }),
        trailer("youtube-dublado", { version: "dubbed" }),
      ],
    }),
  ]);

  assertEquals((await siteMovie(id)).trailer, {
    youtube_key: "youtube-dublado",
    version: "dubbed",
  });
});

Deno.test("num filme que não é falado em português, vale o legendado em português, depois o dublado, depois o original", async () => {
  const [all, noSubtitled, onlyOriginal, otherLanguage] = [newId(), newId(), newId(), newId()];
  const original = trailer("original", { language: "en" });
  const dubbed = trailer("dublado", { version: "dubbed" });
  const subtitled = trailer("legendado", { version: "subtitled" });
  await readMovies([
    catalogMovie("a", all, { original_language: "en", trailers: [original, dubbed, subtitled] }),
    catalogMovie("b", noSubtitled, { original_language: "en", trailers: [original, dubbed] }),
    catalogMovie("c", onlyOriginal, { original_language: "en", trailers: [original] }),
    catalogMovie("d", otherLanguage, {
      original_language: "fr",
      trailers: [original, trailer("frances", { language: "fr" })],
    }),
  ]);

  assertEquals((await siteMovie(all)).trailer, { youtube_key: "legendado", version: "subtitled" });
  assertEquals((await siteMovie(noSubtitled)).trailer, {
    youtube_key: "dublado",
    version: "dubbed",
  });
  assertEquals((await siteMovie(onlyOriginal)).trailer, {
    youtube_key: "original",
    version: "original",
  });
  assertEquals((await siteMovie(otherLanguage)).trailer, {
    youtube_key: "frances",
    version: "original",
  });
});

Deno.test("um trailer em português sem versão conta como dublado", async () => {
  const id = newId();
  await readMovies([
    catalogMovie("a", id, {
      original_language: "en",
      trailers: [trailer("sem-versao"), trailer("original", { language: "en" })],
    }),
  ]);

  assertEquals((await siteMovie(id)).trailer, { youtube_key: "sem-versao", version: "dubbed" });
});

Deno.test("num filme em português, vale o trailer em português", async () => {
  const id = newId();
  await readMovies([
    catalogMovie("a", id, {
      original_language: "pt",
      trailers: [
        trailer("ingles", { language: "en", published_at: "2026-09-20T12:00:00.000Z" }),
        trailer("portugues"),
      ],
    }),
  ]);

  assertEquals((await siteMovie(id)).trailer, { youtube_key: "portugues", version: "original" });
});

Deno.test("dentro da mesma versão, vale o trailer oficial mais recente", async () => {
  const id = newId();
  await readMovies([
    catalogMovie("a", id, {
      original_language: "en",
      trailers: [
        trailer("antigo", { version: "subtitled", published_at: "2026-08-01T12:00:00.000Z" }),
        trailer("recente", { version: "subtitled", published_at: "2026-09-01T12:00:00.000Z" }),
        trailer("nao-oficial", {
          version: "subtitled",
          official: false,
          published_at: "2026-09-30T12:00:00.000Z",
        }),
      ],
    }),
  ]);

  assertEquals((await siteMovie(id)).trailer, { youtube_key: "recente", version: "subtitled" });
});

Deno.test("um filme sem trailer no YouTube fica sem trailer, sem falha", async () => {
  const [onlyVimeo, none] = [newId(), newId()];
  await readMovies([
    catalogMovie("a", onlyVimeo, {
      original_language: "en",
      trailers: [trailer("vimeo", { site: "Vimeo" })],
    }),
    catalogMovie("b", none, { original_language: "en", trailers: [] }),
  ]);

  assertEquals((await siteMovie(onlyVimeo)).trailer, null);
  assertEquals((await siteMovie(none)).trailer, null);
});

Deno.test("a versão só vale para um trailer em português", async () => {
  const monday = newWeek();
  const { status, body } = await read(
    "cine-alquimia",
    "ingresso_com",
    [
      catalogMovie("a", newId(), {
        trailers: [trailer("ingles", { language: "en", version: "subtitled" })],
      }),
    ],
    [session("a", `${monday}T20:00`)],
    at(monday, "12:00"),
  );

  assertEquals(status, 400);
  assertEquals(body.error.issues.map((issue: any) => issue.path), [
    "/reading/movies/0/tmdb/trailers/0/version",
  ]);
});

Deno.test("o plano devolve os campos de metadados que faltam em cada filme conhecido", async () => {
  const [onlyTitles, complete, unknown] = [newId(), newId(), newId()];
  await readMovies([
    catalogMovie("a", onlyTitles, {}),
    catalogMovie("b", complete, {
      imdb_id: "tt0000001",
      overview: "Sinopse.",
      year: 2026,
      countries: ["US"],
      original_language: "en",
      genres: [{ tmdb_id: 18, name: "Drama", english_name: "Drama" }],
      runtime: 100,
      budget: 10,
      revenue: 20,
      content_rating: "12",
      poster_path: await newImage(),
      trailers: [trailer("legendado", { version: "subtitled" })],
      credits: { cast: [], directors: [{ person: person(newId(), "Diretora") }] },
    }),
  ]);

  const { status, body } = await callIngestion("collection-plan", { collection_type: "daily" });
  assertEquals(status, 200);
  const known = new Map(body.known_movies.map((movie: any) => [movie.tmdb_id, movie.missing]));
  assertEquals(known.get(onlyTitles), [
    "imdb_id",
    "overview",
    "year",
    "countries",
    "original_language",
    "genres",
    "runtime",
    "budget",
    "revenue",
    "content_rating",
    "poster_path",
    "trailers",
    "credits",
  ]);
  assertEquals(known.get(complete), []);
  assert(!known.has(unknown));
});

Deno.test("um filme conhecido mantém o identificador quando o título original muda", async () => {
  const id = newId();
  await readMovies([catalogMovie("a", id, { year: 2025 })]);

  await readMovies([{
    key: "a",
    source_title: "Filme a",
    tmdb_id: id,
    tmdb_search_top_id: id,
    tmdb: { original_title: `Corrected ${id}` },
  }]);

  assertEquals(await storedMovie(id, "slug,original_title"), [
    { slug: `movie-${id}`, original_title: `Movie ${id}` },
  ]);
});

Deno.test("um filme conhecido ganha só os campos que faltavam", async () => {
  const id = newId();
  const actress = newId();
  await readMovies([catalogMovie("a", id, { year: 2025, original_language: "en" })]);

  await readMovies([{
    key: "a",
    source_title: "Filme a",
    tmdb_id: id,
    tmdb_search_top_id: id,
    tmdb: {
      title: "Outro título",
      year: 1999,
      overview: "Sinopse que faltava.",
      trailers: [trailer("legendado", { version: "subtitled" })],
      credits: { cast: [{ person: person(actress, "Atriz"), order: 0 }], directors: [] },
    },
  }]);

  const movie = await siteMovie(id);
  assertEquals(
    {
      title: movie.title,
      year: movie.year,
      overview: movie.overview,
      trailer: movie.trailer,
      cast: movie.cast.map((credit: any) => credit.tmdb_id),
    },
    {
      title: `Filme ${id}`,
      year: 2025,
      overview: "Sinopse que faltava.",
      trailer: { youtube_key: "legendado", version: "subtitled" },
      cast: [actress],
    },
  );
});
