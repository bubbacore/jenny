// deno-lint-ignore-file no-explicit-any
import { assertEquals } from "@std/assert";
import { callIngestion, readView, watchmanToken } from "./local.ts";
import { addDays, at, collect, finish, movie, newWeek, read, session, start } from "./reading.ts";

const error = { status: "error", reason: "A fonte não respondeu." };

// The suspension of the automatic publication is one for the whole Bubba, so
// every test that depends on it starts by ending any suspension left open.
function recordSitePublication(clock: string) {
  return callIngestion("record-site-publication", {}, { clock });
}

function recordSiteReversion(clock: string) {
  return callIngestion("record-site-reversion", {}, { clock });
}

function summary(kind: "daily" | "evening", clock: string) {
  return callIngestion("collection-summary", { summary: kind }, { clock });
}

function dailyCollectionStatus(clock: string) {
  return callIngestion("daily-collection-status", {}, { token: watchmanToken, clock });
}

const suspensionLine = "A publicação automática está suspensa desde uma reversão da publicação " +
  "do site. A coleta continua gravando no banco, mas o site só volta a ser publicado quando o " +
  "dono pedir uma publicação do site.";

Deno.test("o fim de uma coleta diária devolve que ela termina com uma publicação do site", async () => {
  const day = newWeek();
  await recordSitePublication(at(day, "05:00"));

  const collection = await collect("daily", at(day, "06:00"));
  const finished = await finish(collection, at(day, "06:40"));
  assertEquals(finished.status, 200);
  assertEquals(finished.body, {
    collection_id: collection,
    site_publication: true,
    automatic_publication_suspended: false,
  });

  const again = await finish(collection, at(day, "06:41"));
  assertEquals(again.status, 409);
  assertEquals(again.body.error.code, "collection_finished");

  const unknown = await finish(crypto.randomUUID(), at(day, "06:41"));
  assertEquals(unknown.status, 400);
  assertEquals(unknown.body.error.issues.map((issue: any) => issue.path), ["/collection_id"]);
});

Deno.test("o fim de uma recoleta publica só quando alguma leitura mudou de resultado", async () => {
  const day = newWeek();
  const movies = [movie("a", 9800001)];
  const sessions = [session("a", `${day}T19:00`)];
  await recordSitePublication(at(day, "05:00"));

  const daily = await collect("daily", at(day, "06:00"));
  await read("cinemark-riomar", "ingresso_com", movies, sessions, at(day, "06:01"), {}, daily);
  await read("cine-alquimia", "ingresso_com", [], [], at(day, "06:02"), error, daily);
  await read("cinemark-riomar", "ingresso_com", [], [], at(day, "06:03"), error, daily);
  await finish(daily, at(day, "06:30"));

  const stillFailing = await collect("recollection", at(day, "08:00"), {
    cinemas: ["cine-alquimia", "cinemark-riomar"],
  });
  await read("cine-alquimia", "ingresso_com", [], [], at(day, "08:01"), error, stillFailing);
  await read("cinemark-riomar", "ingresso_com", [], [], at(day, "08:02"), {
    status: "incomplete",
    reason: "A página de terça não respondeu.",
  }, stillFailing);
  assertEquals((await finish(stillFailing, at(day, "08:10"))).body.site_publication, false);

  const back = await collect("recollection", at(day, "10:00"), {
    cinemas: ["cine-alquimia", "cinemark-riomar"],
  });
  await read("cine-alquimia", "ingresso_com", [], [], at(day, "10:01"), error, back);
  await read("cinemark-riomar", "ingresso_com", movies, sessions, at(day, "10:02"), {}, back);
  assertEquals((await finish(back, at(day, "10:10"))).body.site_publication, true);

  const empty = await collect("recollection", at(day, "12:00"), { cinemas: ["cine-alquimia"] });
  assertEquals((await finish(empty, at(day, "12:10"))).body.site_publication, false);
});

Deno.test("o fim de uma recoleta publica quando alguma leitura libera sessões retidas por identificação pendente", async () => {
  const day = newWeek();
  const title = `Carros (20º Aniversário) ${crypto.randomUUID().slice(0, 8)}`;
  const movies = (proposed: number) => [
    movie("a", 9800001),
    movie("pending", proposed, { source_title: title, tmdb_search_top_id: null }),
  ];
  const sessions = [session("a", `${day}T19:00`), session("pending", `${day}T20:00`)];
  await recordSitePublication(at(day, "05:00"));

  const daily = await collect("daily", at(day, "06:00"));
  const retained = await read(
    "cinemark-riomar",
    "ingresso_com",
    movies(9800005),
    sessions,
    at(day, "06:01"),
    {},
    daily,
  );
  assertEquals(retained.body.sessions.retained, 1);
  await finish(daily, at(day, "06:30"));

  const resolved = await callIngestion("resolve-pending-identification", {
    cinema: "cinemark-riomar",
    source_title: title,
    tmdb_id: 9800005,
  }, { clock: at(day, "07:00") });
  assertEquals(resolved.status, 200);

  const released = await collect("recollection", at(day, "07:05"), {
    cinemas: ["cinemark-riomar"],
  });
  const reading = await read(
    "cinemark-riomar",
    "ingresso_com",
    movies(9800005),
    sessions,
    at(day, "07:06"),
    {},
    released,
  );
  assertEquals(reading.body.result, "success");
  assertEquals(reading.body.sessions.retained, 0);
  assertEquals(
    (await readView("readings", `id=eq.${reading.body.reading_id}&select=sessions_released`))[0],
    { sessions_released: 1 },
  );
  assertEquals((await finish(released, at(day, "07:10"))).body.site_publication, true);

  const nothingNew = await collect("recollection", at(day, "08:00"), {
    cinemas: ["cinemark-riomar"],
  });
  await read(
    "cinemark-riomar",
    "ingresso_com",
    movies(9800005),
    sessions,
    at(day, "08:01"),
    {},
    nothingNew,
  );
  assertEquals((await finish(nothingNew, at(day, "08:10"))).body.site_publication, false);
});

Deno.test("uma coleta avulsa publica por padrão e não publica quando pedida assim", async () => {
  const day = newWeek();
  await recordSitePublication(at(day, "05:00"));

  const byDefault = await collect("manual", at(day, "09:00"), { cinemas: ["cine-alquimia"] });
  assertEquals((await finish(byDefault, at(day, "09:10"))).body.site_publication, true);

  const quiet = await collect("manual", at(day, "10:00"), { site_publication: false });
  assertEquals((await finish(quiet, at(day, "10:10"))).body.site_publication, false);
});

Deno.test("a reversão suspende a publicação automática até o dono pedir uma publicação do site", async () => {
  const day = newWeek();
  await recordSitePublication(at(day, "05:00"));

  const reversion = await recordSiteReversion(at(day, "05:30"));
  assertEquals(reversion.status, 200);
  assertEquals(reversion.body.automatic_publication_suspended, true);
  assertEquals(new Date(reversion.body.suspended_since).toISOString(), `${day}T08:30:00.000Z`);

  // A second reversion keeps the suspension already open.
  const second = await recordSiteReversion(at(day, "05:40"));
  assertEquals(new Date(second.body.suspended_since).toISOString(), `${day}T08:30:00.000Z`);

  const daily = await collect("daily", at(day, "06:00"));
  await read("cine-alquimia", "ingresso_com", [], [], at(day, "06:01"), error, daily);
  assertEquals((await finish(daily, at(day, "06:30"))).body, {
    collection_id: daily,
    site_publication: false,
    automatic_publication_suspended: true,
  });

  const recollection = await collect("recollection", at(day, "08:00"), {
    cinemas: ["cine-alquimia"],
  });
  await read(
    "cine-alquimia",
    "ingresso_com",
    [movie("a", 9800002)],
    [
      session("a", `${day}T19:00`),
    ],
    at(day, "08:01"),
    {},
    recollection,
  );
  assertEquals((await finish(recollection, at(day, "08:10"))).body.site_publication, false);

  const quiet = await collect("manual", at(day, "09:00"), { site_publication: false });
  assertEquals((await finish(quiet, at(day, "09:10"))).body.automatic_publication_suspended, true);

  const ended = await recordSitePublication(at(day, "11:00"));
  assertEquals(ended.body, { automatic_publication_suspended: false, suspension_ended: true });

  const nothingToEnd = await recordSitePublication(at(day, "11:30"));
  assertEquals(nothingToEnd.body.suspension_ended, false);

  const suspensions = await readView(
    "automatic_publication_suspensions",
    `started_at=eq.${encodeURIComponent(at(day, "05:30"))}` +
      "&select=ended_at,ended_by_owner_site_publication_id,ended_by_collection_id",
  );
  assertEquals(suspensions.length, 1);
  assertEquals(new Date(suspensions[0].ended_at).toISOString(), `${day}T14:00:00.000Z`);
  assertEquals(suspensions[0].ended_by_collection_id, null);
});

Deno.test("uma coleta avulsa que publica encerra a suspensão, e o histórico das suspensões fica guardado", async () => {
  const day = newWeek();
  await recordSitePublication(at(day, "05:00"));
  await recordSiteReversion(at(day, "05:30"));

  const manual = await collect("manual", at(day, "09:00"), { cinemas: ["cinema-do-centro"] });
  assertEquals((await finish(manual, at(day, "09:10"))).body, {
    collection_id: manual,
    site_publication: true,
    automatic_publication_suspended: false,
  });

  const daily = await collect("daily", at(addDays(day, 1), "06:00"));
  assertEquals((await finish(daily, at(addDays(day, 1), "06:30"))).body.site_publication, true);

  const [suspension] = await readView(
    "automatic_publication_suspensions",
    `started_at=eq.${encodeURIComponent(at(day, "05:30"))}&select=ended_by_collection_id`,
  );
  assertEquals(suspension.ended_by_collection_id, manual);
});

Deno.test("os resumos de coleta listam os cinemas sem sucesso no dia e informam a suspensão", async () => {
  const day = newWeek();
  const movies = [movie("a", 9800003)];
  const sessions = [session("a", `${day}T19:00`)];
  await recordSitePublication(at(day, "05:00"));

  const daily = await collect("daily", at(day, "06:00"));
  for (
    const [cinema, source] of [
      ["centerplex-parque-shopping", "veloxtickets"],
      ["cinema-do-centro", "official_site"],
      ["cinemark-riomar", "ingresso_com"],
      ["cinemark-shopping-jardins", "ingresso_com"],
      ["cinesercla-praia-sul", "cinesercla_site"],
    ]
  ) {
    await read(cinema, source, movies, sessions, at(day, "06:10"), {}, daily);
  }
  await read("cinesercla-premio", "cinesercla_site", [], [], at(day, "06:20"), error, daily);
  await finish(daily, at(day, "06:30"));

  const morning = await summary("daily", at(day, "06:31"));
  assertEquals(morning.status, 200);
  assertEquals(morning.body, {
    summary: "daily",
    send: true,
    automatic_publication_suspended: false,
    cinemas_without_success: [
      { cinema: "cine-alquimia", name: "Cine Alquimia", failure_type: null, reason: null },
      {
        cinema: "cinesercla-premio",
        name: "Cinesercla Prêmio",
        failure_type: "error",
        reason: "A fonte não respondeu.",
      },
    ],
    text: [
      "Resumo da coleta diária: 5 de 7 cinemas com sucesso.",
      "Sem sucesso:",
      "- Cine Alquimia: sem leitura hoje.",
      "- Cinesercla Prêmio: erro. Motivo: A fonte não respondeu.",
    ].join("\n"),
  });

  await recordSiteReversion(at(day, "09:00"));
  await read("cine-alquimia", "ingresso_com", movies, sessions, at(day, "15:00"));
  await read("cinesercla-premio", "cinesercla_site", [], [], at(day, "20:00"));

  const evening = await summary("evening", at(day, "22:00"));
  assertEquals(evening.body.send, true);
  assertEquals(evening.body.automatic_publication_suspended, true);
  assertEquals(
    evening.body.text,
    [
      "Resumo de coleta das 22h: 1 cinema passou o dia sem sucesso.",
      "- Cinesercla Prêmio: leitura desatualizada. Motivo: A leitura não trouxe nenhuma sessão " +
      "de hoje em diante, e o cinema funciona em algum dia da janela.",
      suspensionLine,
    ].join("\n"),
  );

  assertEquals(
    (await summary("daily", at(day, "22:00"))).body.text.split("\n").at(-1),
    suspensionLine,
  );

  await recordSitePublication(at(day, "22:30"));
  await read("cinesercla-premio", "cinesercla_site", movies, sessions, at(day, "22:40"));
  const quiet = await summary("evening", at(day, "22:50"));
  assertEquals(quiet.body.send, false);
  assertEquals(quiet.body.cinemas_without_success, []);
  assertEquals(quiet.body.automatic_publication_suspended, false);

  const invalid = await callIngestion("collection-summary", { summary: "weekly" });
  assertEquals(invalid.status, 400);
  assertEquals(invalid.body.error.issues.map((issue: any) => issue.path), ["/summary"]);
});

Deno.test("a coleta do dia responde se a coleta diária de hoje terminou", async () => {
  const day = newWeek();
  const tuesday = addDays(day, 1);

  assertEquals((await dailyCollectionStatus(at(day, "12:00"))).body, { finished: false });

  const manual = await collect("manual", at(day, "06:00"));
  await finish(manual, at(day, "06:10"));
  const daily = await collect("daily", at(day, "06:20"));
  assertEquals((await dailyCollectionStatus(at(day, "12:00"))).body, { finished: false });

  await finish(daily, at(day, "06:50"));
  const status = await dailyCollectionStatus(at(day, "12:00"));
  assertEquals(status.status, 200);
  assertEquals(status.body, { finished: true });
  assertEquals((await dailyCollectionStatus(at(day, "06:40"))).body, { finished: false });
  assertEquals((await dailyCollectionStatus(at(tuesday, "12:00"))).body, { finished: false });
});

Deno.test("o token do vigia da coleta só alcança a coleta do dia, e o do Hermes não a alcança", async () => {
  const hermesOperations = [
    "collection-plan",
    "start-reading",
    "record-reading",
    "recollection-cinemas",
    "finish-collection",
    "collection-summary",
    "record-site-reversion",
    "record-site-publication",
  ];
  for (const operation of hermesOperations) {
    const { status, body } = await callIngestion(operation, {}, { token: watchmanToken });
    assertEquals(status, 403, operation);
    assertEquals(body.error.code, "forbidden", operation);
  }

  const { status, body } = await callIngestion("daily-collection-status", {});
  assertEquals(status, 403);
  assertEquals(body.error.code, "forbidden");
});

Deno.test("o início da leitura exige uma coleta em andamento que cubra o cinema", async () => {
  const day = newWeek();

  const unknown = await start("cine-alquimia", at(day, "06:00"), crypto.randomUUID());
  assertEquals(unknown.status, 400);
  assertEquals(unknown.body.error.code, "unknown_collection");
  assertEquals(unknown.body.error.issues.map((issue: any) => issue.path), ["/collection_id"]);

  const other = await collect("manual", at(day, "06:00"), { cinemas: ["cinemark-riomar"] });
  const outside = await start("cine-alquimia", at(day, "06:01"), other);
  assertEquals(outside.status, 400);
  assertEquals(outside.body.error.code, "cinema_not_in_collection");
  assertEquals(outside.body.error.issues.map((issue: any) => issue.path), ["/cinema"]);

  await finish(other, at(day, "06:02"));
  const finished = await start("cinemark-riomar", at(day, "06:03"), other);
  assertEquals(finished.status, 409);
  assertEquals(finished.body.error.code, "collection_finished");

  const missing = await callIngestion("start-reading", { cinema: "cine-alquimia" });
  assertEquals(missing.status, 400);
  assertEquals(missing.body.error.issues.map((issue: any) => issue.path), ["/collection_id"]);
});
