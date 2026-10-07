// deno-lint-ignore-file no-explicit-any
import { assertEquals } from "@std/assert";
import { callIngestion, readView } from "./local.ts";
import { movie, read, reading, record, RELEASE, session, showtimes, start } from "./reading.ts";

Deno.test("uma segunda reserva do mesmo cinema é recusada enquanto a primeira está em andamento", async () => {
  const first = await start("cine-alquimia", "2026-10-05T12:00:00-03:00");
  assertEquals(first.status, 201);
  assertEquals(first.body.cinema, "cine-alquimia");
  assertEquals(new Date(first.body.expires_at).toISOString(), "2026-10-05T15:30:00.000Z");

  const second = await start("cine-alquimia", "2026-10-05T12:29:00-03:00");
  assertEquals(second.status, 409);
  assertEquals(second.body.error.code, "reading_in_progress");

  const otherCinema = await read(
    "cinemark-riomar",
    "ingresso_com",
    [],
    [],
    "2026-10-05T12:10:00-03:00",
  );
  assertEquals(otherCinema.status, 200);

  const recorded = await record(
    first.body.reading_id,
    reading("cine-alquimia", "ingresso_com", [], []),
    "2026-10-05T12:29:00-03:00",
  );
  assertEquals(recorded.status, 200);

  const afterRecord = await start("cine-alquimia", "2026-10-05T12:29:00-03:00");
  assertEquals(afterRecord.status, 201);
  const closed = await record(
    afterRecord.body.reading_id,
    reading("cine-alquimia", "ingresso_com", [], []),
    "2026-10-05T12:29:00-03:00",
  );
  assertEquals(closed.status, 200);
});

Deno.test("uma reserva abandonada expira depois de 30 minutos", async () => {
  const late = await start("cine-alquimia", "2026-10-05T14:00:00-03:00");
  const lateRecord = await record(
    late.body.reading_id,
    reading("cine-alquimia", "ingresso_com", [], []),
    "2026-10-05T14:30:00-03:00",
  );
  assertEquals(lateRecord.status, 409);
  assertEquals(lateRecord.body.error.code, "reservation_expired");

  const abandoned = await start("cine-alquimia", "2026-10-05T15:00:00-03:00");
  const takeover = await start("cine-alquimia", "2026-10-05T15:30:00-03:00");
  assertEquals(takeover.status, 201);

  const abandonedRecord = await record(
    abandoned.body.reading_id,
    reading("cine-alquimia", "ingresso_com", [], []),
    "2026-10-05T15:31:00-03:00",
  );
  assertEquals(abandonedRecord.status, 409);
  assertEquals(abandonedRecord.body.error.code, "reading_closed");

  const takeoverRecord = await record(
    takeover.body.reading_id,
    reading("cine-alquimia", "ingresso_com", [], []),
    "2026-10-05T15:31:00-03:00",
  );
  assertEquals(takeoverRecord.status, 200);
});

Deno.test("o início da leitura recusa um cinema desconhecido ou inativo", async () => {
  for (const cinema of ["cinema-inexistente", "cinema-desativado-de-teste"]) {
    const { status, body } = await start(cinema);
    assertEquals(status, 400, cinema);
    assertEquals(body.error.code, "unknown_cinema");
    assertEquals(body.error.issues.map((issue: any) => issue.path), ["/cinema"]);
  }
});

Deno.test("uma leitura nova substitui tudo o que havia para o cinema", async () => {
  const first = await read("centerplex-parque-shopping", "veloxtickets", [
    movie("a", 9100001),
    movie("b", 9100002),
  ], [
    session("a", "2026-10-05T14:00"),
    session("a", "2026-10-06T14:00"),
    session("b", "2026-10-07T20:00"),
  ]);
  assertEquals(first.status, 200);
  assertEquals(first.body.result, "success");
  assertEquals(first.body.sessions, { received: 3, discarded: 0, accepted: 3, retained: 0 });
  assertEquals((await showtimes("centerplex-parque-shopping")).length, 3);

  const second = await read("centerplex-parque-shopping", "veloxtickets", [movie("c", 9100003)], [
    session("c", "2026-10-08T19:00", { room: "Sala 3", tags: ["VIP"], external_id: "87141252" }),
  ]);
  assertEquals(second.status, 200);
  assertEquals(await showtimes("centerplex-parque-shopping"), [{
    cinema: "centerplex-parque-shopping",
    movie: "movie-9100003",
    starts_at: "2026-10-08T19:00:00",
    date: "2026-10-08",
    room: "Sala 3",
    audio: "dubbed",
    format: "2d",
    tags: ["VIP"],
    prices: [],
    other_tickets: false,
  }]);
  assertEquals(
    (await readView("site_movies", "tmdb_id=in.(9100001,9100002,9100003)")).map((m) => m.tmdb_id),
    [9100003],
  );
});

Deno.test("sessões fora da janela são descartadas e não contam para nenhuma regra", async () => {
  const { status, body } = await read("cinemark-riomar", "ingresso_com", [movie("a", 9100004)], [
    session("a", "2026-10-04T23:30"),
    session("a", "2026-10-05T00:30"),
    session("a", "2026-10-11T23:59"),
    session("a", "2026-10-12T00:00"),
  ]);

  assertEquals(status, 200);
  assertEquals(body.sessions, { received: 4, discarded: 2, accepted: 2, retained: 0 });
  assertEquals((await showtimes("cinemark-riomar")).map((row) => row.starts_at), [
    "2026-10-05T00:30:00",
    "2026-10-11T23:59:00",
  ]);
});

Deno.test("cada sessão pertence à data em que começa, no fuso da cidade, inclusive na madrugada", async () => {
  // 01:30 in UTC is still 22:30 of Monday in Nossa Senhora do Socorro.
  const { status, body } = await read(
    "cinesercla-premio",
    "cinesercla_site",
    [movie("a", 9100005)],
    [
      session("a", "2026-10-05T23:00"),
      session("a", "2026-10-06T00:30"),
      session("a", "2026-10-11T21:00"),
      session("a", "2026-10-12T00:10"),
    ],
    "2026-10-06T01:30:00Z",
  );

  assertEquals(status, 200);
  assertEquals(body.sessions, { received: 4, discarded: 1, accepted: 3, retained: 0 });
  assertEquals(
    (await showtimes("cinesercla-premio")).map((row) => [row.starts_at, row.date]),
    [
      ["2026-10-05T23:00:00", "2026-10-05"],
      ["2026-10-06T00:30:00", "2026-10-06"],
      ["2026-10-11T21:00:00", "2026-10-11"],
    ],
  );
});

Deno.test("uma sessão é única por cinema, filme, início, sala, idioma e formato", async () => {
  const repeated = [
    [
      [movie("a", 9100006)],
      [session("a", "2026-10-05T19:00"), session("a", "2026-10-05T19:00")],
    ],
    [
      [movie("leg", 9100006), movie("dub", 9100006)],
      [session("leg", "2026-10-05T19:00"), session("dub", "2026-10-05T19:00")],
    ],
    [
      [movie("a", 9100006)],
      [
        session("a", "2026-10-05T19:00", { room: undefined, audio: undefined, format: undefined }),
        session("a", "2026-10-05T19:00", { room: undefined, audio: undefined, format: undefined }),
      ],
    ],
  ];
  for (const [movies, sessions] of repeated) {
    const { status, body } = await record(
      crypto.randomUUID(),
      reading("cinemark-shopping-jardins", "ingresso_com", movies, sessions),
    );
    assertEquals(status, 400);
    assertEquals(body.error.issues.map((issue: any) => issue.path), ["/reading/sessions/1"]);
  }

  const distinct = await read("cinemark-shopping-jardins", "ingresso_com", [movie("a", 9100006)], [
    session("a", "2026-10-05T19:00"),
    session("a", "2026-10-05T19:00", { room: "Sala 2" }),
    session("a", "2026-10-05T19:00", { audio: "subtitled" }),
    session("a", "2026-10-05T19:00", { format: "3d" }),
    session("a", "2026-10-05T19:00", { room: undefined, audio: undefined, format: undefined }),
  ]);
  assertEquals(distinct.status, 200);
  assertEquals(distinct.body.sessions.accepted, 5);
  assertEquals((await showtimes("cinemark-shopping-jardins")).length, 5);
});

Deno.test("um filme novo entra com o identificador do TMDB, os títulos do TMDB e um endereço próprio", async () => {
  const { status } = await read("cinemark-shopping-jardins", "ingresso_com", [
    movie("a", 9200001, {
      source_title: "AINDA ESTOU AQUI (NAC)",
      tmdb: { title: "Ainda Estou Aqui", original_title: "Ainda Estou Aqui", year: 2024 },
    }),
    movie("b", 9200002, {
      tmdb: { title: "Ainda Estou Aqui", original_title: "Ainda Estou Aqui", year: 2026 },
    }),
  ], [
    session("a", "2026-10-05T19:00"),
    session("b", "2026-10-05T21:00"),
  ]);

  assertEquals(status, 200);
  assertEquals(
    await readView(
      "site_movies",
      "select=slug,tmdb_id,title,original_title&tmdb_id=in.(9200001,9200002)&order=tmdb_id",
    ),
    [
      {
        slug: "ainda-estou-aqui",
        tmdb_id: 9200001,
        title: "Ainda Estou Aqui",
        original_title: "Ainda Estou Aqui",
      },
      {
        slug: "ainda-estou-aqui-2026",
        tmdb_id: 9200002,
        title: "Ainda Estou Aqui",
        original_title: "Ainda Estou Aqui",
      },
    ],
  );
});

Deno.test("só são aceitas as sessões dos filmes cujo identificador coincide com o primeiro resultado da busca", async () => {
  const { status, body } = await read("cinesercla-praia-sul", "cinesercla_site", [
    movie("match", 9300001),
    movie("diverge", 9300002, { tmdb_search_top_id: 9300099 }),
    movie("no-result", 9300003, { tmdb_search_top_id: null }),
  ], [
    session("match", "2026-10-05T19:00"),
    session("diverge", "2026-10-05T20:00"),
    session("no-result", "2026-10-05T21:00"),
  ]);

  assertEquals(status, 200);
  assertEquals(body.sessions, { received: 3, discarded: 0, accepted: 1, retained: 2 });
  assertEquals((await showtimes("cinesercla-praia-sul")).map((row) => row.movie), [
    "movie-9300001",
  ]);
  assertEquals(
    (await readView("site_movies", "tmdb_id=in.(9300001,9300002,9300003,9300099)")).map((m) =>
      m.tmdb_id
    ),
    [9300001],
  );
});

Deno.test("a sessão guarda o preço de bilheteria por tipo de ingresso quando a fonte o informa", async () => {
  const { status } = await read("cinesercla-praia-sul", "cinesercla_site", [movie("a", 9300004)], [
    session("a", "2026-10-05T19:00", {
      prices: [
        { source_ticket: "PROMO TERÇA", kind: "promo", price_cents: 1500 },
        { source_ticket: "MEIA", kind: "half", price_cents: 2100 },
        { source_ticket: "INTEIRA", kind: "full", price_cents: 4200 },
        { source_ticket: "MEIA WEB PRO", price_cents: 1800 },
      ],
    }),
  ]);

  assertEquals(status, 200);
  assertEquals((await showtimes("cinesercla-praia-sul"))[0].prices, [
    { ticket_type: "full", source_ticket: "INTEIRA", price_cents: 4200 },
    { ticket_type: "half", source_ticket: "MEIA", price_cents: 2100 },
    { ticket_type: "promo", source_ticket: "PROMO TERÇA", price_cents: 1500 },
  ]);
});

Deno.test("a leitura fica no histórico com o release da coleta, o início, o fim e as contagens", async () => {
  // A source title new to every run, so its pending identification is new.
  const run = crypto.randomUUID().slice(0, 8);
  const first = await read("cinema-do-centro", "official_site", [movie("a", 9400001)], [
    session("a", "2026-10-05T16:00"),
    session("a", "2026-10-05T18:00"),
  ], "2026-10-05T12:02:00-03:00");
  assertEquals(first.status, 200);

  const started = await start("cinema-do-centro", "2026-10-05T12:03:00-03:00");
  const recorded = await record(
    started.body.reading_id,
    reading("cinema-do-centro", "official_site", [
      movie("a", 9400001),
      movie("b", 9400002, { tmdb_search_top_id: 9400099, source_title: `Filme b ${run}` }),
    ], [
      session("a", "2026-10-05T16:00"),
      session("b", "2026-10-05T18:00"),
      session("a", "2026-10-15T16:00"),
    ]),
    "2026-10-05T12:05:00-03:00",
    "v0.4.2",
  );
  assertEquals(recorded.status, 200);
  assertEquals(recorded.body.reading_id, started.body.reading_id);

  const [history] = await readView(
    "readings",
    `id=eq.${started.body.reading_id}&select=status,collection_release,started_at,finished_at,` +
      "sessions_received,sessions_discarded,sessions_accepted,sessions_retained,previous_sessions," +
      "session_dates,alerts",
  );
  assertEquals({
    ...history,
    started_at: new Date(history.started_at).toISOString(),
    finished_at: new Date(history.finished_at).toISOString(),
  }, {
    status: "success",
    collection_release: "v0.4.2",
    started_at: "2026-10-05T15:03:00.000Z",
    finished_at: "2026-10-05T15:05:00.000Z",
    sessions_received: 3,
    sessions_discarded: 1,
    sessions_accepted: 1,
    sessions_retained: 1,
    previous_sessions: 2,
    session_dates: ["2026-10-05", "2026-10-05"],
    alerts: recorded.body.alerts,
  });
  assertEquals(
    recorded.body.alerts.map((alert: any) => alert.subject),
    [`pending-identification:cinema-do-centro:filme b ${run}`],
  );
});

Deno.test("o registro recusa uma leitura que não confere com a reserva ou com o acervo", async () => {
  const started = await start("cinema-do-centro");
  const id = started.body.reading_id;

  const otherCinema = await record(id, reading("cine-alquimia", "ingresso_com", [], []));
  assertEquals(otherCinema.status, 400);
  assertEquals(otherCinema.body.error.code, "invalid_reading");
  assertEquals(otherCinema.body.error.issues.map((issue: any) => issue.path), [
    "/reading/cinema",
    "/reading/source",
  ]);

  const untitled = await record(
    id,
    reading("cinema-do-centro", "official_site", [movie("a", 9500001, { tmdb: undefined })], []),
  );
  assertEquals(untitled.status, 400);
  assertEquals(untitled.body.error.issues.map((issue: any) => issue.path), [
    "/reading/movies/0/tmdb",
  ]);

  const created = await record(
    id,
    reading("cinema-do-centro", "official_site", [movie("a", 9500002)], [
      session("a", "2026-10-05T16:00"),
    ]),
  );
  assertEquals(created.status, 200);

  const again = await record(id, reading("cinema-do-centro", "official_site", [], []));
  assertEquals(again.status, 409);
  assertEquals(again.body.error.code, "reading_closed");

  const known = await read("cinema-do-centro", "official_site", [
    movie("a", 9500002, { tmdb: undefined }),
  ], [session("a", "2026-10-05T16:00")]);
  assertEquals(known.status, 200);
  assertEquals(known.body.sessions.accepted, 1);

  const unknown = await record(
    crypto.randomUUID(),
    reading("cinema-do-centro", "official_site", [], []),
  );
  assertEquals(unknown.status, 400);
  assertEquals(unknown.body.error.code, "unknown_reading");
  assertEquals(unknown.body.error.issues.map((issue: any) => issue.path), ["/reading_id"]);
});

Deno.test("uma leitura fora do contrato é recusada com o caminho de cada campo errado", async () => {
  const valid = () => ({
    reading_id: crypto.randomUUID(),
    collection_release: RELEASE,
    reading: reading("cine-alquimia", "ingresso_com", [movie("a", 9600001)], [
      session("a", "2026-10-05T19:00", {
        tags: ["XD"],
        prices: [{ source_ticket: "INTEIRA", kind: "full", price_cents: 4200 }],
      }),
    ]),
  });
  const cases: [string, (body: any) => void, string[]][] = [
    ["classificação fora da lista", (b) => b.reading.movies[0].content_rating = "em análise", [
      "/reading/movies/0/content_rating",
    ]],
    ["classificação como número", (b) => b.reading.movies[0].content_rating = 12, [
      "/reading/movies/0/content_rating",
    ]],
    ["erro sem motivo", (b) => b.reading.status = "error", ["/reading/reason"]],
    ["incompleta sem motivo", (b) => b.reading.status = "incomplete", ["/reading/reason"]],
    ["motivo numa leitura ok", (b) => b.reading.reason = "nada", ["/reading/reason"]],
    ["status desconhecido", (b) => b.reading.status = "partial", ["/reading/status"]],
    ["fonte desconhecida", (b) => b.reading.source = "instagram", ["/reading/source"]],
    ["cinema fora do formato", (b) => b.reading.cinema = "Cine Alquimia", ["/reading/cinema"]],
    ["tmdb_id como texto", (b) => b.reading.movies[0].tmdb_id = "9600001", [
      "/reading/movies/0/tmdb_id",
    ]],
    ["chave de filme repetida", (b) => b.reading.movies.push(movie("a", 9600002)), [
      "/reading/movies/1/key",
    ]],
    ["sessão de filme fora da leitura", (b) => b.reading.sessions[0].movie_key = "x", [
      "/reading/sessions/0/movie_key",
    ]],
    ["início com espaço", (b) => b.reading.sessions[0].starts_at = "2026-10-05 19:00", [
      "/reading/sessions/0/starts_at",
    ]],
    ["início com fuso", (b) => b.reading.sessions[0].starts_at = "2026-10-05T19:00-03:00", [
      "/reading/sessions/0/starts_at",
    ]],
    ["data inexistente", (b) => b.reading.sessions[0].starts_at = "2026-02-30T19:00", [
      "/reading/sessions/0/starts_at",
    ]],
    ["idioma fora da lista", (b) => b.reading.sessions[0].audio = "legendado", [
      "/reading/sessions/0/audio",
    ]],
    ["sala em branco", (b) => b.reading.sessions[0].room = "  ", ["/reading/sessions/0/room"]],
    ["marcador repetido", (b) => b.reading.sessions[0].tags.push("XD"), [
      "/reading/sessions/0/tags/1",
    ]],
    ["link de compra", (b) => b.reading.sessions[0].link = "https://exemplo.com", [
      "/reading/sessions/0/link",
    ]],
    ["taxa de conveniência", (b) => b.reading.sessions[0].prices[0].convenience_fee_cents = 500, [
      "/reading/sessions/0/prices/0/convenience_fee_cents",
    ]],
    ["tipo de ingresso fora da lista", (b) => b.reading.sessions[0].prices[0].kind = "fee", [
      "/reading/sessions/0/prices/0/kind",
    ]],
    ["preço zerado", (b) => b.reading.sessions[0].prices[0].price_cents = 0, [
      "/reading/sessions/0/prices/0/price_cents",
    ]],
    ["preço com fração de centavo", (b) => b.reading.sessions[0].prices[0].price_cents = 4200.5, [
      "/reading/sessions/0/prices/0/price_cents",
    ]],
    [
      "ingresso na fonte repetido",
      (b) => b.reading.sessions[0].prices.push({ source_ticket: "INTEIRA", price_cents: 4000 }),
      ["/reading/sessions/0/prices/1/source_ticket"],
    ],
    ["ano do filme proposto fora do intervalo", (b) => b.reading.movies[0].tmdb_year = 1500, [
      "/reading/movies/0/tmdb_year",
    ]],
    [
      "título do primeiro resultado sem resultado da busca",
      (b) => {
        b.reading.movies[0].tmdb_search_top_id = null;
        b.reading.movies[0].tmdb_search_top_title = "Filme";
      },
      ["/reading/movies/0/tmdb_search_top_title"],
    ],
    ["release fora do formato", (b) => b.collection_release = "0.1.0", ["/collection_release"]],
    ["leitura sem identificador", (b) => b.reading_id = "abc", ["/reading_id"]],
    ["sem a leitura", (b) => delete b.reading, ["/reading"]],
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
