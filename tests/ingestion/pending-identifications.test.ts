// deno-lint-ignore-file no-explicit-any
import { assert, assertEquals } from "@std/assert";
import { callIngestion, readView } from "./local.ts";
import {
  addDays,
  at,
  cinemaDays,
  dayMonth,
  movie,
  newWeek,
  read,
  session,
  showtimes,
  window,
} from "./reading.ts";

// Source titles new to every run, so each pending identification is new and
// the remembered resolutions of earlier runs do not apply.
const run = crypto.randomUUID().slice(0, 8);

function resolve(body: unknown, clock?: string) {
  return callIngestion("resolve-pending-identification", body, { clock });
}

function alertsOf(type: string, alerts: any[]) {
  return alerts.filter((alert) => alert.type === type);
}

async function pendingIdentification(normalizedSourceTitle: string) {
  const rows = await readView(
    "pending_identifications",
    `normalized_source_title=eq.${encodeURIComponent(normalizedSourceTitle)}` +
      "&select=source_title,proposed_tmdb_id,search_top_tmdb_id,proposed_title,proposed_year," +
      "search_top_title,search_top_year,reason,status,resolved_tmdb_id," +
      "first_seen_at,last_seen_at,resolved_at,cinema:cinemas(slug)",
  );
  assertEquals(rows.length, 1, normalizedSourceTitle);
  const [row] = rows;
  return {
    ...row,
    cinema: row.cinema.slug,
    first_seen_at: new Date(row.first_seen_at).toISOString(),
    last_seen_at: new Date(row.last_seen_at).toISOString(),
    resolved_at: row.resolved_at && new Date(row.resolved_at).toISOString(),
  };
}

Deno.test("um filme cujo identificador proposto difere do primeiro resultado da busca vira identificação pendente, e as demais sessões são aceitas", async () => {
  const day = newWeek();
  const legendado = `Vingadores (Leg) ${run}`;
  const cineclube = `Sessão  Cineclube ${run}`;
  const { status, body } = await read("cinemark-shopping-jardins", "ingresso_com", [
    movie("match", 9800001),
    movie("diverge", 9800002, {
      source_title: legendado,
      tmdb_search_top_id: 9800003,
      tmdb_title: "Vingadores: Ultimato",
      tmdb_year: 2019,
      tmdb_search_top_title: "Vingadores: Guerra Infinita",
      tmdb_search_top_year: 2018,
    }),
    movie("no-result", 9800004, {
      source_title: cineclube,
      tmdb_search_top_id: null,
      tmdb_title: "Sessão Cineclube",
    }),
  ], [
    session("match", `${day}T19:00`),
    session("diverge", `${day}T20:00`),
    session("diverge", `${day}T22:00`),
    session("no-result", `${day}T21:00`),
  ], at(day, "08:00"));

  assertEquals(status, 200);
  assertEquals(body.result, "success");
  assertEquals(body.sessions, { received: 4, discarded: 0, accepted: 1, retained: 3 });
  assertEquals((await showtimes("cinemark-shopping-jardins")).map((row) => row.movie), [
    "movie-9800001",
  ]);
  assertEquals(alertsOf("pending-identification", body.alerts), [
    {
      type: "pending-identification",
      subject: `pending-identification:cinemark-shopping-jardins:sessao cineclube ${run}`,
      effect: "open",
      text: `Cinemark Shopping Jardins: o título na fonte "${cineclube}" ficou em identificação ` +
        "pendente, com 1 sessão retida. O filme proposto é Sessão Cineclube, TMDB 9800004, mas a " +
        "busca pelo título na fonte e pelo ano não trouxe resultado. Aceite o filme proposto ou " +
        "escolha outro para liberar as sessões.\n" +
        "Filme proposto: https://www.themoviedb.org/movie/9800004",
      proposed_movie: { tmdb_id: 9800004, title: "Sessão Cineclube" },
    },
    {
      type: "pending-identification",
      subject: `pending-identification:cinemark-shopping-jardins:vingadores (leg) ${run}`,
      effect: "open",
      text: `Cinemark Shopping Jardins: o título na fonte "${legendado}" ficou em identificação ` +
        "pendente, com 2 sessões retidas. O filme proposto é Vingadores: Ultimato (2019), TMDB " +
        "9800002, mas o primeiro resultado da busca pelo título na fonte e pelo ano é Vingadores: " +
        "Guerra Infinita (2018), TMDB 9800003. Aceite o filme proposto ou escolha outro para " +
        "liberar as sessões.\n" +
        "Filme proposto: https://www.themoviedb.org/movie/9800002\n" +
        "Primeiro resultado: https://www.themoviedb.org/movie/9800003",
      proposed_movie: { tmdb_id: 9800002, title: "Vingadores: Ultimato", year: 2019 },
    },
  ]);
  assertEquals(await pendingIdentification(`vingadores (leg) ${run}`), {
    cinema: "cinemark-shopping-jardins",
    source_title: legendado,
    proposed_tmdb_id: 9800002,
    search_top_tmdb_id: 9800003,
    proposed_title: "Vingadores: Ultimato",
    proposed_year: 2019,
    search_top_title: "Vingadores: Guerra Infinita",
    search_top_year: 2018,
    reason: "O filme proposto é Vingadores: Ultimato (2019), TMDB 9800002, mas o primeiro " +
      "resultado da busca pelo título na fonte e pelo ano é Vingadores: Guerra Infinita (2018), " +
      "TMDB 9800003.",
    status: "pending",
    resolved_tmdb_id: null,
    first_seen_at: new Date(at(day, "08:00")).toISOString(),
    last_seen_at: new Date(at(day, "08:00")).toISOString(),
    resolved_at: null,
  });
});

Deno.test("uma nova aparição no mesmo dia atualiza a identificação pendente, sem alertar de novo", async () => {
  const day = newWeek();
  const title = `Duna Parte 3 ${run}`;
  const diverging = (proposed: number) =>
    movie("diverge", proposed, { source_title: title, tmdb_search_top_id: 9800023 });

  await read("cinemark-riomar", "ingresso_com", [diverging(9800021)], [
    session("diverge", `${day}T20:00`),
  ], at(day, "08:00"));
  const again = await read("cinemark-riomar", "ingresso_com", [
    movie("match", 9800024),
    diverging(9800022),
  ], [
    session("match", `${day}T19:00`),
    session("diverge", `${day}T20:00`),
  ], at(day, "10:00"));

  assertEquals(again.body.result, "success");
  assertEquals(alertsOf("pending-identification", again.body.alerts), []);
  const pending = await pendingIdentification(`duna parte 3 ${run}`);
  assertEquals(pending.proposed_tmdb_id, 9800022);
  assertEquals(pending.first_seen_at, new Date(at(day, "08:00")).toISOString());
  assertEquals(pending.last_seen_at, new Date(at(day, "10:00")).toISOString());
});

Deno.test("a primeira leitura do cinema em cada dia seguinte alerta de novo a identificação pendente, e as outras leituras do dia não repetem o alerta", async () => {
  const day = newWeek();
  const sessionDay = addDays(day, 3);
  const title = `Missão Impossível (Dub) ${run}`;
  const subject = `pending-identification:cinemark-riomar:missao impossivel (dub) ${run}`;
  const reminder = (since: string) =>
    `Cinemark RioMar: o título na fonte "${title}" continua em identificação pendente desde ` +
    `${since}, com 2 sessões retidas. O filme proposto é o TMDB 9800072, mas o primeiro ` +
    "resultado da busca pelo título na fonte e pelo ano é o TMDB 9800073. Aceite o filme " +
    "proposto ou escolha outro para liberar as sessões.\n" +
    "Filme proposto: https://www.themoviedb.org/movie/9800072\n" +
    "Primeiro resultado: https://www.themoviedb.org/movie/9800073";
  const readAt = (clock: string) =>
    read("cinemark-riomar", "ingresso_com", [
      movie("match", 9800071),
      movie("diverge", 9800072, { source_title: title, tmdb_search_top_id: 9800073 }),
    ], [
      session("match", `${sessionDay}T19:00`),
      session("diverge", `${sessionDay}T20:00`),
      session("diverge", `${sessionDay}T22:00`),
    ], clock);

  const first = await readAt(at(day, "08:00"));
  assertEquals(
    alertsOf("pending-identification", first.body.alerts).map((alert) => [
      alert.subject,
      alert.effect,
    ]),
    [[subject, "open"]],
  );

  const nextDay = await readAt(at(addDays(day, 1), "08:00"));
  assertEquals(nextDay.body.result, "success");
  assertEquals(alertsOf("pending-identification", nextDay.body.alerts), [{
    type: "pending-identification",
    subject,
    effect: "open",
    text: reminder(dayMonth(day)),
    proposed_movie: { tmdb_id: 9800072 },
  }]);

  const sameDay = await readAt(at(addDays(day, 1), "10:00"));
  assertEquals(alertsOf("pending-identification", sameDay.body.alerts), []);

  const later = await readAt(at(addDays(day, 2), "07:00"));
  assertEquals(alertsOf("pending-identification", later.body.alerts), [{
    type: "pending-identification",
    subject,
    effect: "open",
    text: reminder(dayMonth(day)),
    proposed_movie: { tmdb_id: 9800072 },
  }]);

  const pending = await pendingIdentification(`missao impossivel (dub) ${run}`);
  assertEquals([pending.status, pending.first_seen_at, pending.last_seen_at], [
    "pending",
    new Date(at(day, "08:00")).toISOString(),
    new Date(at(addDays(day, 2), "07:00")).toISOString(),
  ]);
});

Deno.test("o dia do alerta da identificação pendente segue o fuso da cidade do cinema", async () => {
  const day = newWeek();
  const nextDay = addDays(day, 1);
  const title = `Pré-estreia: Batman ${run}`;
  // Every session is retained, so each reading is a retained reading, and
  // the later ones of the same day are its recollections.
  const readAt = (clock: string) =>
    read("cinesercla-premio", "cinesercla_site", [
      movie("diverge", 9800082, { source_title: title, tmdb_search_top_id: 9800083 }),
    ], [
      session("diverge", `${addDays(day, 3)}T19:00`),
    ], clock);

  // 20:00 in Socorro is 23:00 UTC, and 23:30 there is already the next day
  // in UTC, but still the same day in the city.
  const first = await readAt(at(day, "20:00"));
  assertEquals(alertsOf("pending-identification", first.body.alerts).length, 1);

  const lateRecollection = await readAt(at(day, "23:30"));
  assertEquals(lateRecollection.body.failure_type, "retained");
  assertEquals(alertsOf("pending-identification", lateRecollection.body.alerts), []);

  // 08:00 of the next day in the city is the same day in UTC as the last
  // reading, and it is the first reading of a new day in the city.
  const morning = await readAt(at(nextDay, "08:00"));
  assertEquals(alertsOf("pending-identification", morning.body.alerts).map((alert) => alert.text), [
    `Cinesercla Prêmio: o título na fonte "${title}" continua em identificação pendente desde ` +
    `${dayMonth(day)}, com 1 sessão retida. O filme proposto é o TMDB 9800082, mas o primeiro ` +
    "resultado da busca pelo título na fonte e pelo ano é o TMDB 9800083. Aceite o filme " +
    "proposto ou escolha outro para liberar as sessões.\n" +
    "Filme proposto: https://www.themoviedb.org/movie/9800082\n" +
    "Primeiro resultado: https://www.themoviedb.org/movie/9800083",
  ]);
});

Deno.test("uma identificação resolvida não alerta nos dias seguintes", async () => {
  const day = newWeek();
  const title = `Coringa 3 ${run}`;
  const readAt = (clock: string) =>
    read("cine-alquimia", "ingresso_com", [
      movie("diverge", 9800092, { source_title: title, tmdb_search_top_id: 9800093 }),
    ], [
      session("diverge", `${addDays(day, 3)}T20:00`),
    ], clock);

  const first = await readAt(at(day, "08:00"));
  assertEquals(alertsOf("pending-identification", first.body.alerts).length, 1);
  const resolved = await resolve(
    { cinema: "cine-alquimia", source_title: title, tmdb_id: 9800092 },
    at(day, "09:00"),
  );
  assertEquals(resolved.status, 200);

  const nextDay = await readAt(at(addDays(day, 1), "08:00"));
  assertEquals(nextDay.body.result, "success");
  assertEquals(nextDay.body.sessions.retained, 0);
  assertEquals(alertsOf("pending-identification", nextDay.body.alerts), []);
});

Deno.test("uma leitura com todas as sessões retidas é leitura retida e apaga a programação do cinema", async () => {
  const day = newWeek();
  const title = `Pré-estreia: Avatar ${run}`;

  const before = await read("cinesercla-premio", "cinesercla_site", [movie("a", 9800031)], [
    session("a", `${day}T19:00`),
  ], at(day, "08:00"));
  assertEquals(before.body.result, "success");

  const { status, body } = await read("cinesercla-premio", "cinesercla_site", [
    movie("diverge", 9800032, { source_title: title, tmdb_search_top_id: 9800033 }),
  ], [
    session("diverge", `${day}T19:00`),
    session("diverge", `${day}T21:00`),
  ], at(day, "10:00"));

  assertEquals(status, 200);
  assertEquals(body.result, "failure");
  assertEquals(body.failure_type, "retained");
  assertEquals(
    body.reason,
    "Todas as sessões da leitura ficaram retidas por identificação pendente (2 sessões)",
  );
  assertEquals(body.sessions, { received: 2, discarded: 0, accepted: 0, retained: 2 });
  assertEquals(body.alerts.map((alert: any) => [alert.type, alert.effect]), [
    ["collection-failure", "open"],
    ["pending-identification", "open"],
  ]);
  assertEquals(
    body.alerts[0].text,
    "Cinesercla Prêmio: leitura com falha (leitura retida). Motivo: Todas as sessões da leitura " +
      "ficaram retidas por identificação pendente (2 sessões). A programação do cinema foi " +
      'apagada, e o site mostra "atualizando".',
  );
  assertEquals(await showtimes("cinesercla-premio"), []);
  assertEquals(
    await cinemaDays("cinesercla-premio", at(day, "10:00")),
    window(day).map((date) => [date, "updating"]),
  );
  const [history] = await readView(
    "readings",
    `id=eq.${body.reading_id}&select=status,failure_type,sessions_retained`,
  );
  assertEquals(history, { status: "failure", failure_type: "retained", sessions_retained: 2 });
});

Deno.test("a resolução grava o título na fonte resolvido, devolve o cinema a recoletar e o alerta que resolve a ocorrência", async () => {
  const day = newWeek();
  const title = `Divertida Mente 2 - 3D DUB ${run}`;
  const normalized = `divertida mente 2 - 3d dub ${run}`;
  const opened = await read("cine-alquimia", "ingresso_com", [
    movie("a", 9800041),
    movie("diverge", 9800042, { source_title: title, tmdb_search_top_id: 9800043 }),
  ], [
    session("a", `${day}T18:00`),
    session("diverge", `${day}T20:00`),
  ], at(day, "08:00"));
  assertEquals(alertsOf("pending-identification", opened.body.alerts).length, 1);

  // The title as the owner types it may differ in case and spacing.
  const resolved = await resolve({
    cinema: "cine-alquimia",
    source_title: `  DIVERTIDA  MENTE 2 - 3d dub ${run}`,
    tmdb_id: 9800044,
  }, at(day, "09:00"));

  assertEquals(resolved.status, 200);
  assertEquals(resolved.body, {
    recollection_cinema: "cine-alquimia",
    alerts: [{
      type: "pending-identification",
      subject: `pending-identification:cine-alquimia:${normalized}`,
      effect: "resolve",
      text: `Cine Alquimia: o título na fonte "${title}" foi ligado ao TMDB 9800044. ` +
        "O cinema será recoletado para liberar as sessões.",
    }],
  });
  assertEquals(
    alertsOf("pending-identification", opened.body.alerts)[0].subject,
    resolved.body.alerts[0].subject,
  );
  const pending = await pendingIdentification(normalized);
  assertEquals([pending.status, pending.resolved_tmdb_id, pending.resolved_at], [
    "resolved",
    9800044,
    new Date(at(day, "09:00")).toISOString(),
  ]);

  const plan = await callIngestion("collection-plan", {
    collection_type: "manual",
    cinemas: ["cine-alquimia"],
  }, { clock: at(day, "09:30") });
  assertEquals(plan.status, 200);
  assert(
    plan.body.cinemas[0].resolved_source_titles.some((resolvedTitle: any) =>
      resolvedTitle.source_title === title && resolvedTitle.tmdb_id === 9800044
    ),
    JSON.stringify(plan.body.cinemas[0].resolved_source_titles),
  );

  // The recollection: the Hermes sends the chosen movie, and the search
  // result no longer decides.
  const recollected = await read("cine-alquimia", "ingresso_com", [
    movie("a", 9800041),
    movie("resolved", 9800044, {
      source_title: title.toLowerCase(),
      tmdb_search_top_id: 9800043,
    }),
  ], [
    session("a", `${day}T18:00`),
    session("resolved", `${day}T20:00`),
  ], at(day, "10:00"));

  assertEquals(recollected.body.result, "success");
  assertEquals(recollected.body.sessions.retained, 0);
  assertEquals(alertsOf("pending-identification", recollected.body.alerts), []);
  assertEquals((await showtimes("cine-alquimia")).map((row) => row.movie), [
    "movie-9800041",
    "movie-9800044",
  ]);

  // Another proposal for the same source title still uses the chosen movie.
  const otherProposal = await read("cine-alquimia", "ingresso_com", [
    movie("resolved", 9800045, { source_title: title }),
  ], [
    session("resolved", `${day}T20:00`),
  ], at(day, "12:00"));

  assertEquals(otherProposal.body.result, "success");
  assertEquals((await showtimes("cine-alquimia")).map((row) => row.movie), ["movie-9800044"]);
  assertEquals(await readView("site_movies", "tmdb_id=eq.9800045"), []);

  const again = await resolve({ cinema: "cine-alquimia", source_title: title, tmdb_id: 9800044 });
  assertEquals(again.status, 400);
  assertEquals(again.body.error.code, "unknown_identification");
});

Deno.test("a resolução recusa um título sem identificação pendente no cinema e uma requisição fora do contrato", async () => {
  const day = newWeek();
  const title = `Maratona Senhor dos Anéis ${run}`;
  await read(
    "centerplex-parque-shopping",
    "veloxtickets",
    [
      movie("diverge", 9800051, { source_title: title, tmdb_search_top_id: 9800052 }),
    ],
    [session("diverge", `${day}T20:00`)],
    at(day, "08:00"),
  );

  const otherCinema = await resolve({ cinema: "cinemark-riomar", source_title: title, tmdb_id: 1 });
  assertEquals(otherCinema.status, 400);
  assertEquals(otherCinema.body.error.code, "unknown_identification");
  assertEquals(otherCinema.body.error.issues.map((issue: any) => issue.path), ["/source_title"]);

  for (
    const [request, paths] of [
      [{ cinema: "centerplex-parque-shopping", source_title: title }, ["/tmdb_id"]],
      [{ cinema: "Centerplex", source_title: " ", tmdb_id: 0 }, [
        "/cinema",
        "/source_title",
        "/tmdb_id",
      ]],
      [{ cinema: "centerplex-parque-shopping", source_title: title, tmdb_id: 1, extra: true }, [
        "/extra",
      ]],
    ] as const
  ) {
    const { status, body } = await resolve(request);
    assertEquals(status, 400, JSON.stringify(request));
    assertEquals(body.error.code, "invalid_request");
    assertEquals(body.error.issues.map((issue: any) => issue.path), paths, JSON.stringify(request));
  }

  const pending = await pendingIdentification(`maratona senhor dos aneis ${run}`);
  assertEquals(pending.status, "pending");
});

Deno.test("uma leitura com falha informada pelo Hermes não cria identificação pendente", async () => {
  const day = newWeek();
  const title = `Filme Incompleto ${run}`;
  const { body } = await read(
    "cinemark-riomar",
    "ingresso_com",
    [
      movie("diverge", 9800061, { source_title: title, tmdb_search_top_id: 9800062 }),
    ],
    [session("diverge", `${day}T20:00`)],
    at(day, "08:00"),
    {
      status: "incomplete",
      reason: "A página de terça não respondeu.",
    },
  );

  assertEquals(body.failure_type, "incomplete");
  assertEquals(alertsOf("pending-identification", body.alerts), []);
  assertEquals(
    await readView(
      "pending_identifications",
      `normalized_source_title=eq.${encodeURIComponent(`filme incompleto ${run}`)}`,
    ),
    [],
  );
});
