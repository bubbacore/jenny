// deno-lint-ignore-file no-explicit-any
import { assertEquals } from "@std/assert";
import { callIngestion, readView } from "./local.ts";
import { at, movie, newTmdbId, newWeek, read, session } from "./reading.ts";

// The calculation looks back 8 weeks, so each window takes 9 weeks of its own,
// and only the last one gets readings or the calculation.
function newWindow(): string {
  for (let week = 0; week < 8; week++) newWeek();
  return newWeek();
}

function updateReliability(clock: string) {
  return callIngestion("update-source-reliability", {}, { clock });
}

// A calculation over a window without readings leaves every source type in
// the initial ranking, which the choice tests assume.
async function resetRanking() {
  const { status, body } = await updateReliability(at(newWindow(), "12:00"));
  assertEquals(status, 200, JSON.stringify(body));
  assertEquals(body.ranking.map((place: any) => place.source_type), [
    "ingresso_com",
    "veloxtickets",
    "cinesercla_site",
    "official_site",
  ]);
}

// Reads the movies in the cinema, each with one session on the same day, and
// checks that the reading succeeded.
async function readIn(cinema: string, source: string, movies: any[], date: string, time: string) {
  const response = await read(
    cinema,
    source,
    movies,
    movies.map((entry) => session(entry.key, `${date}T22:00`)),
    at(date, time),
  );
  assertEquals(response.status, 200, JSON.stringify(response.body));
  assertEquals(response.body.result, "success", JSON.stringify(response.body));
  return response.body;
}

function rated(tmdbId: number, contentRating?: string, extra: Record<string, unknown> = {}) {
  return movie(`m${tmdbId}`, tmdbId, {
    ...(contentRating ? { content_rating: contentRating } : {}),
    ...extra,
  });
}

async function chosen(tmdbId: number): Promise<any> {
  const [stored] = await readView(
    "movies",
    "select=content_rating,content_rating_source_type,overview,overview_source_type," +
      `trailer_youtube_key,trailer_version,trailer_source_type&tmdb_id=eq.${tmdbId}`,
  );
  return stored;
}

Deno.test("com certificação do Brasil no TMDB, vale o TMDB, mesmo quando uma fonte principal informa outro valor, sem alerta", async () => {
  const id = newTmdbId();
  const monday = newWeek();
  const entry = movie(`m${id}`, id, {
    content_rating: "16",
    tmdb: { title: `Filme ${id}`, original_title: `Movie ${id}`, content_rating: "12" },
  });
  await readIn("cinesercla-praia-sul", "cinesercla_site", [entry], monday, "12:00");
  const second = await readIn("cinesercla-praia-sul", "cinesercla_site", [entry], monday, "13:00");

  assertEquals(second.alerts, []);
  assertEquals((await chosen(id)).content_rating, "12");
  assertEquals((await chosen(id)).content_rating_source_type, null);
  const [site] = await readView("site_movies", `select=content_rating&tmdb_id=eq.${id}`);
  assertEquals(site.content_rating, "12");
});

Deno.test("sem o TMDB, vale a fonte principal de maior confiabilidade, e no empate vale a leitura mais recente", async () => {
  await resetRanking();
  const [ranked, tied] = [newTmdbId(), newTmdbId()];
  const monday = newWeek();

  await readIn("cinesercla-praia-sul", "cinesercla_site", [rated(ranked, "16")], monday, "10:00");
  assertEquals((await chosen(ranked)).content_rating, "16");
  await readIn("cinemark-riomar", "ingresso_com", [rated(ranked, "14")], monday, "11:00");
  await readIn("cinesercla-premio", "cinesercla_site", [rated(ranked, "18")], monday, "12:00");
  assertEquals(
    {
      content_rating: (await chosen(ranked)).content_rating,
      source_type: (await chosen(ranked)).content_rating_source_type,
    },
    { content_rating: "14", source_type: "ingresso_com" },
  );

  await readIn("cinemark-riomar", "ingresso_com", [rated(tied, "14")], monday, "13:00");
  await readIn("cinemark-shopping-jardins", "ingresso_com", [rated(tied, "16")], monday, "14:00");
  assertEquals((await chosen(tied)).content_rating, "16");
  await readIn("cinemark-riomar", "ingresso_com", [rated(tied, "12")], monday, "15:00");
  assertEquals((await chosen(tied)).content_rating, "12");
});

Deno.test("o valor muda quando uma fonte mais confiável passa a informá-lo e quando o TMDB passa a tê-lo", async () => {
  await resetRanking();
  const id = newTmdbId();
  const monday = newWeek();

  await readIn("cinema-do-centro", "official_site", [rated(id, "14")], monday, "10:00");
  assertEquals((await chosen(id)).content_rating_source_type, "official_site");
  await readIn("centerplex-parque-shopping", "veloxtickets", [rated(id, "16")], monday, "11:00");
  assertEquals(
    [(await chosen(id)).content_rating, (await chosen(id)).content_rating_source_type],
    ["16", "veloxtickets"],
  );

  await readIn(
    "cinema-do-centro",
    "official_site",
    [rated(id, "14", { tmdb: { content_rating: "18" } })],
    monday,
    "12:00",
  );
  assertEquals(
    [(await chosen(id)).content_rating, (await chosen(id)).content_rating_source_type],
    ["18", null],
  );
});

Deno.test("a falta de classificação indicativa não é falha nem gera alerta", async () => {
  const id = newTmdbId();
  const monday = newWeek();
  await readIn("cinemark-riomar", "ingresso_com", [rated(id)], monday, "12:00");
  const second = await readIn("cinemark-riomar", "ingresso_com", [rated(id)], monday, "13:00");

  assertEquals(second.alerts, []);
  assertEquals((await chosen(id)).content_rating, null);
  const [site] = await readView("site_movies", `select=content_rating&tmdb_id=eq.${id}`);
  assertEquals(site.content_rating, null);
});

Deno.test("a sinopse e o trailer ausentes no TMDB seguem a mesma escolha", async () => {
  await resetRanking();
  const [fromSources, withTmdb] = [newTmdbId(), newTmdbId()];
  const monday = newWeek();
  const tmdb = (id: number, extra: Record<string, unknown> = {}) => ({
    title: `Filme ${id}`,
    original_title: `Movie ${id}`,
    original_language: "en",
    ...extra,
  });

  await readIn(
    "centerplex-parque-shopping",
    "veloxtickets",
    [
      rated(fromSources, undefined, {
        tmdb: tmdb(fromSources),
        overview: "Sinopse do Veloxtickets.",
        trailer: { url: "https://www.youtube.com/watch?v=velox000001" },
      }),
      rated(withTmdb, undefined, {
        tmdb: tmdb(withTmdb, {
          overview: "Sinopse do TMDB.",
          trailers: [{
            site: "YouTube",
            key: "tmdbdubbed1",
            language: "pt",
            version: "dubbed",
            official: true,
            published_at: "2026-09-01T12:00:00Z",
          }],
        }),
        overview: "Sinopse do Veloxtickets.",
        trailer: { url: "https://youtu.be/velox000002", version: "dubbed" },
      }),
    ],
    monday,
    "10:00",
  );
  await readIn(
    "cinemark-riomar",
    "ingresso_com",
    [
      rated(fromSources, undefined, {
        overview: "Sinopse da ingresso.com.",
        trailer: { url: "https://vimeo.com/123456", version: "subtitled" },
      }),
    ],
    monday,
    "11:00",
  );

  assertEquals(await chosen(fromSources), {
    content_rating: null,
    content_rating_source_type: null,
    overview: "Sinopse da ingresso.com.",
    overview_source_type: "ingresso_com",
    trailer_youtube_key: "velox000001",
    trailer_version: "dubbed",
    trailer_source_type: "veloxtickets",
  });
  assertEquals(
    [
      (await chosen(withTmdb)).overview,
      (await chosen(withTmdb)).trailer_youtube_key,
      (await chosen(withTmdb)).trailer_source_type,
    ],
    ["Sinopse do TMDB.", "tmdbdubbed1", null],
  );

  // The version comes before the origin, even from a less reliable source.
  await readIn(
    "cinesercla-praia-sul",
    "cinesercla_site",
    [
      rated(withTmdb, undefined, {
        trailer: { url: "https://www.youtube.com/embed/sercla00001?rel=0", version: "subtitled" },
      }),
    ],
    monday,
    "12:00",
  );
  assertEquals(
    [
      (await chosen(withTmdb)).trailer_youtube_key,
      (await chosen(withTmdb)).trailer_version,
      (await chosen(withTmdb)).trailer_source_type,
    ],
    ["sercla00001", "subtitled", "cinesercla_site"],
  );
});

Deno.test("a fórmula conta só divergências entre tipos de fonte principal diferentes, contra a minoria quando há três ou mais", async () => {
  await resetRanking();
  const monday = newWindow();
  const ids = Array.from({ length: 12 }, () => newTmdbId());
  const sameType = newTmdbId();

  await readIn(
    "cinemark-riomar",
    "ingresso_com",
    [
      ...ids.map((id) => rated(id, "14")),
      rated(sameType, "14"),
    ],
    monday,
    "10:00",
  );
  await readIn(
    "cinemark-shopping-jardins",
    "ingresso_com",
    [rated(sameType, "16")],
    monday,
    "10:30",
  );
  await readIn(
    "centerplex-parque-shopping",
    "veloxtickets",
    ids.map((id) => rated(id, "14")),
    monday,
    "11:00",
  );
  await readIn(
    "cinesercla-praia-sul",
    "cinesercla_site",
    ids.map((id, index) => rated(id, index < 3 ? "16" : "14")),
    monday,
    "12:00",
  );

  const { status, body } = await updateReliability(at(monday, "23:00"));
  assertEquals(status, 200, JSON.stringify(body));
  assertEquals(body.changed, false);
  assertEquals(body.alerts, []);
  assertEquals(
    body.ranking.map(({ position, source_type, compared, divergences, reason }: any) => [
      position,
      source_type,
      compared,
      divergences,
      reason,
    ]),
    [
      [1, "ingresso_com", 12, 0, "ingresso.com: 0 divergências em 12 filmes comparados (0%)"],
      [2, "veloxtickets", 12, 0, "Veloxtickets: 0 divergências em 12 filmes comparados (0%)"],
      [
        3,
        "cinesercla_site",
        12,
        3,
        "site da Cinesercla: 3 divergências em 12 filmes comparados (25%)",
      ],
      [
        4,
        "official_site",
        0,
        0,
        "site oficial: 0 divergências em 0 filmes comparados, menos de 10; mantém a posição do ranking inicial",
      ],
    ],
  );
});

Deno.test("sem maioria, a divergência conta contra todos os tipos de fonte que divergem", async () => {
  await resetRanking();
  const monday = newWindow();
  const id = newTmdbId();
  await readIn("cinemark-riomar", "ingresso_com", [rated(id, "14")], monday, "10:00");
  await readIn("centerplex-parque-shopping", "veloxtickets", [rated(id, "16")], monday, "11:00");

  const { body } = await updateReliability(at(monday, "23:00"));
  assertEquals(
    body.ranking.slice(0, 2).map(({ compared, divergences }: any) => [compared, divergences]),
    [[1, 1], [1, 1]],
  );
});

Deno.test("a fórmula considera só as últimas 8 semanas", async () => {
  await resetRanking();
  const old = newWeek();
  const monday = newWindow();
  const id = newTmdbId();
  await readIn("cinemark-riomar", "ingresso_com", [rated(id, "14")], old, "10:00");
  await readIn("centerplex-parque-shopping", "veloxtickets", [rated(id, "16")], old, "11:00");

  const { body } = await updateReliability(at(monday, "23:00"));
  assertEquals(body.ranking.map((place: any) => place.compared), [0, 0, 0, 0]);
});

Deno.test("um tipo de fonte com menos de 10 filmes comparados fica na posição do ranking inicial", async () => {
  await resetRanking();
  const monday = newWindow();
  const diverging = Array.from({ length: 9 }, () => newTmdbId());
  const others = Array.from({ length: 3 }, () => newTmdbId());

  await readIn(
    "cinemark-riomar",
    "ingresso_com",
    [...diverging, ...others].map((id) => rated(id, "14")),
    monday,
    "10:00",
  );
  await readIn(
    "cinesercla-praia-sul",
    "cinesercla_site",
    [...diverging, ...others].map((id) => rated(id, "14")),
    monday,
    "11:00",
  );
  await readIn(
    "centerplex-parque-shopping",
    "veloxtickets",
    diverging.map((id) => rated(id, "16")),
    monday,
    "12:00",
  );

  const { body } = await updateReliability(at(monday, "23:00"));
  assertEquals(body.changed, false);
  assertEquals(body.ranking[1], {
    position: 2,
    source_type: "veloxtickets",
    compared: 9,
    divergences: 9,
    reason:
      "Veloxtickets: 9 divergências em 9 filmes comparados, menos de 10; mantém a posição do ranking inicial",
  });
});

// Reads 12 movies in three source types, with ingresso.com diverging in the
// first ones.
async function readDivergingIngresso(diverging: number) {
  const monday = newWindow();
  const ids = Array.from({ length: 12 }, () => newTmdbId());
  await readIn(
    "cinemark-riomar",
    "ingresso_com",
    ids.map((id, index) => rated(id, index < diverging ? "16" : "14")),
    monday,
    "10:00",
  );
  await readIn(
    "centerplex-parque-shopping",
    "veloxtickets",
    ids.map((id) => rated(id, "14")),
    monday,
    "11:00",
  );
  await readIn(
    "cinesercla-praia-sul",
    "cinesercla_site",
    ids.map((id) => rated(id, "14")),
    monday,
    "12:00",
  );
  return { monday, ids };
}

Deno.test("dois tipos de fonte só trocam de posição com mais de 10 pontos percentuais de diferença", async () => {
  await resetRanking();
  const { monday } = await readDivergingIngresso(1);

  const { body } = await updateReliability(at(monday, "23:00"));
  assertEquals(body.changed, false);
  assertEquals(body.ranking[0].reason, "ingresso.com: 1 divergência em 12 filmes comparados (8%)");
});

Deno.test("uma mudança no ranking recalcula os filmes afetados e devolve source-reliability com inform; sem mudança, nenhum alerta", async () => {
  await resetRanking();
  const { monday, ids } = await readDivergingIngresso(4);
  assertEquals((await chosen(ids[0])).content_rating, "16");

  const { body } = await updateReliability(at(monday, "23:00"));
  assertEquals(body.changed, true);
  assertEquals(body.ranking.map((place: any) => place.source_type), [
    "veloxtickets",
    "cinesercla_site",
    "ingresso_com",
    "official_site",
  ]);
  assertEquals(body.alerts, [{
    type: "source-reliability",
    subject: "source-reliability",
    effect: "inform",
    text: [
      "A confiabilidade da fonte mudou:",
      "1. Veloxtickets: 0 divergências em 12 filmes comparados (0%)",
      "2. site da Cinesercla: 0 divergências em 12 filmes comparados (0%)",
      "3. ingresso.com: 4 divergências em 12 filmes comparados (33%)",
      "4. site oficial: 0 divergências em 0 filmes comparados, menos de 10; mantém a posição do ranking inicial",
    ].join("\n"),
  }]);
  assertEquals(
    [(await chosen(ids[0])).content_rating, (await chosen(ids[0])).content_rating_source_type],
    ["14", "veloxtickets"],
  );

  const again = await updateReliability(at(monday, "23:30"));
  assertEquals(again.body.changed, false);
  assertEquals(again.body.alerts, []);

  await resetRanking();
  assertEquals((await chosen(ids[0])).content_rating, "16");
});
