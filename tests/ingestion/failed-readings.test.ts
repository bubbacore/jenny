// deno-lint-ignore-file no-explicit-any
import { assertEquals } from "@std/assert";
import { callIngestion, readView } from "./local.ts";
import { cinemaDays, movie, read, session, showtimes } from "./reading.ts";

// Each test runs in its own week, picked at random on every run and far from
// the dates of the other tests. A cinema's history in that week is then only
// what the test records, and the alerts do not depend on earlier runs. The
// first reading of each test may still close something left by another run,
// so its alerts are not checked.
const runBlock = Math.floor(Math.random() * 10_000);

// The Monday of the test's week, in Aracaju and Nossa Senhora do Socorro.
function monday(test: number): string {
  return addDays("2027-01-04", 7 * (runBlock * 10 + test));
}

function addDays(date: string, days: number): string {
  const day = new Date(`${date}T00:00:00Z`);
  day.setUTCDate(day.getUTCDate() + days);
  return day.toISOString().slice(0, 10);
}

// A time in the cities of v1, which are always at UTC-3.
function at(date: string, time: string): string {
  return `${date}T${time}:00-03:00`;
}

function window(date: string): string[] {
  return [0, 1, 2, 3, 4, 5, 6].map((day) => addDays(date, day));
}

function dayMonth(date: string): string {
  return `${date.slice(8, 10)}/${date.slice(5, 7)}`;
}

const error = { status: "error", reason: "A fonte não respondeu." };

Deno.test("uma leitura com erro ou incompleta apaga a programação, e todos os dias do cinema ficam atualizando", async () => {
  const day = monday(0);
  const [, tuesday] = window(day);
  const movies = [movie("a", 9700001)];
  const sessions = [session("a", `${day}T19:00`), session("a", `${tuesday}T19:00`)];

  const before = await read("cinemark-riomar", "ingresso_com", movies, sessions, at(day, "08:00"));
  assertEquals(before.body.result, "success");
  assertEquals((await showtimes("cinemark-riomar")).length, 2);

  const failed = await read("cinemark-riomar", "ingresso_com", [], [], at(day, "10:00"), error);
  assertEquals(failed.status, 200);
  assertEquals(failed.body.result, "failure");
  assertEquals(failed.body.failure_type, "error");
  assertEquals(failed.body.reason, "A fonte não respondeu.");
  assertEquals(failed.body.sessions, { received: 0, discarded: 0, accepted: 0, retained: 0 });
  assertEquals(await showtimes("cinemark-riomar"), []);
  assertEquals(
    await cinemaDays("cinemark-riomar", at(day, "10:00")),
    window(day).map((date) => [date, "updating"]),
  );

  const [history] = await readView(
    "readings",
    `id=eq.${failed.body.reading_id}&select=status,failure_type,reason`,
  );
  assertEquals(history, {
    status: "failure",
    failure_type: "error",
    reason: "A fonte não respondeu.",
  });

  const back = await read("cinemark-riomar", "ingresso_com", movies, sessions, at(day, "12:00"));
  assertEquals(back.body.result, "success");
  assertEquals(back.body.failure_type, undefined);
  assertEquals((await showtimes("cinemark-riomar")).length, 2);

  const incomplete = await read(
    "cinemark-riomar",
    "ingresso_com",
    movies,
    sessions,
    at(day, "14:00"),
    { status: "incomplete", reason: "A página de terça não respondeu." },
  );
  assertEquals(incomplete.body.result, "failure");
  assertEquals(incomplete.body.failure_type, "incomplete");
  assertEquals(incomplete.body.sessions, { received: 2, discarded: 0, accepted: 0, retained: 0 });
  assertEquals(await showtimes("cinemark-riomar"), []);
  assertEquals(
    await cinemaDays("cinemark-riomar", at(day, "14:00")),
    window(day).map((date) => [date, "updating"]),
  );
});

Deno.test("uma leitura sem nenhuma sessão de hoje em diante, com algum dia de funcionamento na janela, é leitura desatualizada", async () => {
  const day = monday(1);
  const sunday = addDays(day, -1);
  const movies = [movie("a", 9700002)];

  await read("centerplex-parque-shopping", "veloxtickets", movies, [
    session("a", `${day}T19:00`),
  ], at(day, "08:00"));

  for (
    const [time, sessions] of [
      ["10:00", [session("a", `${sunday}T19:00`)]],
      ["11:00", []],
    ] as const
  ) {
    const { status, body } = await read(
      "centerplex-parque-shopping",
      "veloxtickets",
      movies,
      [...sessions],
      at(day, time),
    );
    assertEquals(status, 200, time);
    assertEquals(body.result, "failure", time);
    assertEquals(body.failure_type, "outdated", time);
    assertEquals(
      body.reason,
      "A leitura não trouxe nenhuma sessão de hoje em diante, e o cinema funciona em algum dia da janela.",
    );
    assertEquals(body.sessions.accepted, 0, time);
    assertEquals(await showtimes("centerplex-parque-shopping"), [], time);
    assertEquals(
      await cinemaDays("centerplex-parque-shopping", at(day, time)),
      window(day).map((date) => [date, "updating"]),
      time,
    );
  }
});

Deno.test("cada dia da janela tem um só estado: com sessões, dia sem funcionamento ou dia não divulgado", async () => {
  // The Cinema do Centro is closed on Tuesdays and Wednesdays.
  const day = monday(2);
  const [, tuesday, wednesday, thursday, friday, saturday, sunday] = window(day);

  const { body } = await read("cinema-do-centro", "official_site", [movie("a", 9700003)], [
    session("a", `${day}T16:00`),
    session("a", `${thursday}T18:00`),
  ], at(day, "08:00"));
  assertEquals(body.result, "success");

  assertEquals(await cinemaDays("cinema-do-centro", at(day, "08:00")), [
    [day, "with_sessions"],
    [tuesday, "closed"],
    [wednesday, "closed"],
    [thursday, "with_sessions"],
    [friday, "not_announced"],
    [saturday, "not_announced"],
    [sunday, "not_announced"],
  ]);
});

Deno.test("uma sessão em dia sem funcionamento é descartada e gera closed-day-session", async () => {
  const day = monday(3);
  const [, tuesday, wednesday] = window(day);
  const movies = [movie("a", 9700004)];

  await read("cinema-do-centro", "official_site", movies, [
    session("a", `${day}T16:00`),
  ], at(day, "07:00"));

  const { body } = await read("cinema-do-centro", "official_site", movies, [
    session("a", `${day}T16:00`),
    session("a", `${wednesday}T18:00`),
    session("a", `${tuesday}T18:00`),
  ], at(day, "08:00"));

  assertEquals(body.result, "success");
  assertEquals(body.sessions, { received: 3, discarded: 2, accepted: 1, retained: 0 });
  assertEquals(body.alerts, [{
    type: "closed-day-session",
    subject: "closed-day-session:cinema-do-centro",
    effect: "open",
    text: `Cinema do Centro: 2 sessões foram descartadas em dia sem funcionamento (${
      dayMonth(tuesday)
    }, ${dayMonth(wednesday)}). Confira se os dias de funcionamento do cinema mudaram.`,
  }]);
  assertEquals((await showtimes("cinema-do-centro")).map((row) => row.date), [day]);
});

Deno.test("uma queda de mais da metade das sessões aceita as sessões e gera session-drop", async () => {
  const day = monday(4);
  const movies = [movie("a", 9700005)];
  const sessions = (amount: number) =>
    window(day).slice(0, amount).map((date) => session("a", `${date}T19:00`));
  const readSessions = (amount: number, time: string) =>
    read("cinesercla-praia-sul", "cinesercla_site", movies, sessions(amount), at(day, time));

  await readSessions(4, "07:00");

  const half = await readSessions(2, "08:00");
  assertEquals(half.body.alerts, []);

  await readSessions(4, "09:00");

  const drop = await readSessions(1, "10:00");
  assertEquals(drop.body.result, "success");
  assertEquals(drop.body.sessions.accepted, 1);
  assertEquals(drop.body.alerts, [{
    type: "session-drop",
    subject: "session-drop:cinesercla-praia-sul",
    effect: "open",
    text:
      "Cinesercla Praia Sul: queda brusca de sessões, de 4 na última leitura com sucesso para 1 nesta. As sessões foram aceitas.",
  }]);
  assertEquals((await showtimes("cinesercla-praia-sul")).length, 1);
});

Deno.test("a primeira falha do dia abre collection-failure, e o sucesso seguinte a resolve", async () => {
  const day = monday(5);
  const tuesday = addDays(day, 1);
  const movies = [movie("a", 9700006)];
  const sessions = [session("a", `${tuesday}T19:00`)];
  const subject = "collection-failure:cine-alquimia";
  const failed = (failure: string, reason: string) => [{
    type: "collection-failure",
    subject,
    effect: "open",
    text:
      `Cine Alquimia: leitura com falha (${failure}). Motivo: ${reason}. A programação do cinema foi apagada, e o site mostra "atualizando".`,
  }];

  await read("cine-alquimia", "ingresso_com", movies, sessions, at(day, "07:00"));

  const first = await read("cine-alquimia", "ingresso_com", [], [], at(day, "08:00"), error);
  assertEquals(first.body.alerts, failed("erro", "A fonte não respondeu"));

  const repeated = await read("cine-alquimia", "ingresso_com", [], [], at(day, "10:00"));
  assertEquals(repeated.body.failure_type, "outdated");
  assertEquals(repeated.body.alerts, []);

  const back = await read("cine-alquimia", "ingresso_com", movies, sessions, at(day, "12:00"));
  assertEquals(back.body.alerts, [{
    type: "collection-failure",
    subject,
    effect: "resolve",
    text: "Cine Alquimia: a leitura voltou a ter sucesso, com 1 sessão aceita.",
  }]);

  const again = await read("cine-alquimia", "ingresso_com", movies, sessions, at(day, "14:00"));
  assertEquals(again.body.alerts, []);

  const evening = await read("cine-alquimia", "ingresso_com", [], [], at(day, "20:00"), {
    status: "incomplete",
    reason: "A página de sábado não respondeu.",
  });
  assertEquals(
    evening.body.alerts,
    failed("leitura incompleta", "A página de sábado não respondeu"),
  );

  // Still failing on the next day: the first failure of the new day alerts
  // again, and the open occurrence takes it.
  const nextDay = await read("cine-alquimia", "ingresso_com", [], [], at(tuesday, "06:00"), error);
  assertEquals(nextDay.body.alerts, failed("erro", "A fonte não respondeu"));
});

Deno.test("os cinemas para recoleta são os de última leitura do dia com falha, até as 22h", async () => {
  const day = monday(6);
  const sunday = addDays(day, -1);
  const movies = [movie("a", 9700007)];
  const sessions = [session("a", `${day}T19:00`)];
  const recollection = (time: string) =>
    callIngestion("recollection-cinemas", {}, { clock: at(day, time) });

  await read("centerplex-parque-shopping", "veloxtickets", [], [], at(sunday, "20:00"), error);
  await read("cinemark-shopping-jardins", "ingresso_com", [], [], at(day, "06:00"), error);
  await read("cinesercla-premio", "cinesercla_site", [], [], at(day, "06:05"), error);
  await read("cinemark-riomar", "ingresso_com", [], [], at(day, "06:10"), error);
  await read("cinemark-riomar", "ingresso_com", movies, sessions, at(day, "08:00"));

  const morning = await recollection("08:30");
  assertEquals(morning.status, 200);
  assertEquals(morning.body, { cinemas: ["cinemark-shopping-jardins", "cinesercla-premio"] });

  await read("cinemark-shopping-jardins", "ingresso_com", movies, sessions, at(day, "10:00"));
  assertEquals((await recollection("21:59")).body, { cinemas: ["cinesercla-premio"] });
  assertEquals((await recollection("22:00")).body, { cinemas: [] });

  const unknownField = await callIngestion("recollection-cinemas", { cinemas: [] });
  assertEquals(unknownField.status, 400);
  assertEquals(unknownField.body.error.issues.map((issue: any) => issue.path), ["/cinemas"]);
});

Deno.test("a ausência de preço de bilheteria não é falha e não gera alerta", async () => {
  const day = monday(7);
  const movies = [movie("a", 9700008)];
  const priced = [session("a", `${day}T19:00`, {
    prices: [{ source_ticket: "INTEIRA", kind: "full", price_cents: 4200 }],
  })];

  await read("cinemark-shopping-jardins", "ingresso_com", movies, priced, at(day, "07:00"));

  const { body } = await read("cinemark-shopping-jardins", "ingresso_com", movies, [
    session("a", `${day}T19:00`),
  ], at(day, "08:00"));
  assertEquals(body.result, "success");
  assertEquals(body.sessions.accepted, 1);
  assertEquals(body.alerts, []);
  assertEquals((await showtimes("cinemark-shopping-jardins"))[0].prices, []);
});
