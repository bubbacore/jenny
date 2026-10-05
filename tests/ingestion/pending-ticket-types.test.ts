// deno-lint-ignore-file no-explicit-any
import { assertEquals } from "@std/assert";
import { callIngestion } from "./local.ts";
import { at, movie, newWeek, read, session, showtimes } from "./reading.ts";

// Source tickets new to every run, so each one enters pending ticket type and
// the assignments of earlier runs do not apply.
const run = crypto.randomUUID().slice(0, 8);

function resolve(body: unknown) {
  return callIngestion("resolve-pending-ticket-type", body);
}

function alertsOf(alerts: any[]) {
  return alerts.filter((alert) => alert.type === "unknown-ticket-type");
}

const full = { source_ticket: "INTEIRA", kind: "full", price_cents: 4200 };

// Reads the cinema with one session priced with the given values.
function readPriced(cinema: string, source: string, day: string, time: string, prices: unknown[]) {
  return read(cinema, source, [movie("a", 9900001)], [
    session("a", `${day}T20:00`, { prices }),
  ], at(day, time));
}

async function sessionPrices(cinema: string) {
  const [row] = await showtimes(cinema);
  return { prices: row.prices, other_tickets: row.other_tickets };
}

Deno.test("um ingresso na fonte sem tipo de ingresso fica em tipo de ingresso pendente, fora das visões, e só a primeira aparição alerta", async () => {
  const day = newWeek();
  const partner = `Meia Bradesco ${run}`;

  const first = await readPriced("cinemark-shopping-jardins", "ingresso_com", day, "08:00", [
    full,
    { source_ticket: partner, price_cents: 2100 },
  ]);

  assertEquals(first.status, 200);
  assertEquals(first.body.result, "success");
  assertEquals(first.body.sessions.accepted, 1);
  assertEquals(alertsOf(first.body.alerts), [{
    type: "unknown-ticket-type",
    subject: `unknown-ticket-type:ingresso_com:meia bradesco ${run}`,
    effect: "open",
    text: `ingresso.com: o ingresso na fonte "${partner}" ficou em tipo de ingresso pendente. ` +
      "Cinemark Shopping Jardins o informou em 1 sessão, com R$ 21,00. Atribua o tipo de " +
      "ingresso ou indique que ele não é preço de bilheteria; até lá, o valor fica fora do site.",
  }]);
  assertEquals(await sessionPrices("cinemark-shopping-jardins"), {
    prices: [{ ticket_type: "full", source_ticket: "INTEIRA", price_cents: 4200 }],
    other_tickets: true,
  });

  const again = await readPriced("cinemark-shopping-jardins", "ingresso_com", day, "10:00", [
    { source_ticket: partner, price_cents: 2100 },
  ]);
  const otherCinema = await readPriced("cinemark-riomar", "ingresso_com", day, "10:00", [
    { source_ticket: partner.toUpperCase(), price_cents: 1900 },
  ]);

  assertEquals(alertsOf(again.body.alerts), []);
  assertEquals(alertsOf(otherCinema.body.alerts), []);
  assertEquals(await sessionPrices("cinemark-riomar"), { prices: [], other_tickets: true });
});

Deno.test("o alerta da primeira aparição mostra a faixa de valores e as sessões do ingresso na fonte", async () => {
  const day = newWeek();
  const vip = `VIP Casal ${run}`;
  const { body } = await read("centerplex-parque-shopping", "veloxtickets", [
    movie("a", 9900002),
  ], [
    session("a", `${day}T18:00`, { prices: [{ source_ticket: vip, price_cents: 6800 }] }),
    session("a", `${day}T21:00`, { prices: [{ source_ticket: vip, price_cents: 7400 }] }),
  ], at(day, "08:00"));

  assertEquals(alertsOf(body.alerts).map((alert) => alert.text), [
    `Veloxtickets: o ingresso na fonte "${vip}" ficou em tipo de ingresso pendente. ` +
    "Centerplex Parque Shopping o informou em 2 sessões, com valores de R$ 68,00 a R$ 74,00. Atribua o " +
    "tipo de ingresso ou indique que ele não é preço de bilheteria; até lá, o valor fica fora do site.",
  ]);
});

Deno.test("a resolução vale para os valores guardados de todos os cinemas do mesmo tipo de fonte, sem recoleta", async () => {
  const day = newWeek();
  const partner = `Meia Itaú ${run}`;
  await readPriced("cinemark-shopping-jardins", "ingresso_com", day, "08:00", [
    full,
    { source_ticket: partner, price_cents: 2100 },
  ]);
  await readPriced("cinemark-riomar", "ingresso_com", day, "08:00", [
    { source_ticket: partner, price_cents: 2200 },
  ]);
  await readPriced("cinema-do-centro", "official_site", day, "08:00", [
    { source_ticket: partner, price_cents: 1000 },
  ]);

  const { status, body } = await resolve({
    source_type: "ingresso_com",
    source_ticket: partner.toLowerCase(),
    assignment: "half",
  });

  assertEquals(status, 200);
  assertEquals(body, {
    alerts: [{
      type: "unknown-ticket-type",
      subject: `unknown-ticket-type:ingresso_com:meia itau ${run}`,
      effect: "resolve",
      text: `ingresso.com: o ingresso na fonte "${partner}" agora é meia em todos os cinemas ` +
        "deste tipo de fonte. Valores guardados atualizados: 2. Eles aparecem na próxima " +
        "publicação do site.",
    }],
  });
  assertEquals(await sessionPrices("cinemark-shopping-jardins"), {
    prices: [
      { ticket_type: "full", source_ticket: "INTEIRA", price_cents: 4200 },
      { ticket_type: "half", source_ticket: partner, price_cents: 2100 },
    ],
    other_tickets: false,
  });
  assertEquals(await sessionPrices("cinemark-riomar"), {
    prices: [{ ticket_type: "half", source_ticket: partner, price_cents: 2200 }],
    other_tickets: false,
  });
  assertEquals(await sessionPrices("cinema-do-centro"), { prices: [], other_tickets: true });

  const next = await readPriced("cinemark-riomar", "ingresso_com", day, "10:00", [
    { source_ticket: partner, price_cents: 2300 },
  ]);
  assertEquals(alertsOf(next.body.alerts), []);
  assertEquals(await sessionPrices("cinemark-riomar"), {
    prices: [{ ticket_type: "half", source_ticket: partner, price_cents: 2300 }],
    other_tickets: false,
  });
});

Deno.test("um ingresso na fonte que não é preço de bilheteria nunca aparece nas visões", async () => {
  const day = newWeek();
  const combo = `Combo Pipoca ${run}`;
  await readPriced("cinesercla-praia-sul", "cinesercla_site", day, "08:00", [
    full,
    { source_ticket: combo, price_cents: 5500 },
  ]);

  const { body } = await resolve({
    source_type: "cinesercla_site",
    source_ticket: combo,
    assignment: "not_box_office",
  });

  assertEquals(body.alerts.map((alert: any) => [alert.effect, alert.text]), [[
    "resolve",
    `site da Cinesercla: o ingresso na fonte "${combo}" não é preço de bilheteria e nunca ` +
    "aparece no site, em nenhum cinema deste tipo de fonte. Valores guardados descartados: 1.",
  ]]);
  const expected = {
    prices: [{ ticket_type: "full", source_ticket: "INTEIRA", price_cents: 4200 }],
    other_tickets: false,
  };
  assertEquals(await sessionPrices("cinesercla-praia-sul"), expected);

  const next = await readPriced("cinesercla-premio", "cinesercla_site", day, "10:00", [
    full,
    { source_ticket: combo, price_cents: 5500 },
  ]);
  assertEquals(alertsOf(next.body.alerts), []);
  assertEquals(await sessionPrices("cinesercla-premio"), expected);
});

Deno.test("um tipo de ingresso informado pela fonte diferente do atribuído mantém o atribuído e alerta uma vez", async () => {
  const day = newWeek();
  const student = `Meia Estudante ${run}`;
  await readPriced("centerplex-parque-shopping", "veloxtickets", day, "08:00", [
    { source_ticket: student, price_cents: 2100 },
  ]);
  await resolve({ source_type: "veloxtickets", source_ticket: student, assignment: "half" });

  const agreeing = await readPriced("centerplex-parque-shopping", "veloxtickets", day, "09:00", [
    { source_ticket: student, kind: "half", price_cents: 2100 },
  ]);
  assertEquals(alertsOf(agreeing.body.alerts), []);

  const disagreeing = await readPriced("centerplex-parque-shopping", "veloxtickets", day, "10:00", [
    { source_ticket: student, kind: "promo", price_cents: 2100 },
  ]);
  assertEquals(alertsOf(disagreeing.body.alerts), [{
    type: "unknown-ticket-type",
    subject: `unknown-ticket-type:veloxtickets:meia estudante ${run}`,
    effect: "open",
    text: `Veloxtickets: Centerplex Parque Shopping informou o ingresso na fonte "${student}" ` +
      "como promoção, mas ele está atribuído como meia. Vale a atribuição até você revê-la.",
  }]);
  assertEquals(await sessionPrices("centerplex-parque-shopping"), {
    prices: [{ ticket_type: "half", source_ticket: student, price_cents: 2100 }],
    other_tickets: false,
  });

  const repeated = await readPriced("centerplex-parque-shopping", "veloxtickets", day, "11:00", [
    { source_ticket: student, kind: "promo", price_cents: 2100 },
  ]);
  assertEquals(alertsOf(repeated.body.alerts), []);

  const reviewed = await resolve({
    source_type: "veloxtickets",
    source_ticket: student,
    assignment: "promo",
  });
  assertEquals(reviewed.body.alerts.map((alert: any) => alert.effect), ["resolve"]);
  assertEquals((await sessionPrices("centerplex-parque-shopping")).prices, [
    { ticket_type: "promo", source_ticket: student, price_cents: 2100 },
  ]);
});

Deno.test("um ingresso na fonte com tipo de ingresso informado pela fonte e sem atribuição usa o informado, sem alerta", async () => {
  const day = newWeek();
  const promo = `Promo Segunda ${run}`;
  const { body } = await readPriced("cine-alquimia", "ingresso_com", day, "08:00", [
    { source_ticket: promo, kind: "promo", price_cents: 1500 },
  ]);

  assertEquals(alertsOf(body.alerts), []);
  assertEquals(await sessionPrices("cine-alquimia"), {
    prices: [{ ticket_type: "promo", source_ticket: promo, price_cents: 1500 }],
    other_tickets: false,
  });

  const unknown = await resolve({
    source_type: "ingresso_com",
    source_ticket: promo,
    assignment: "full",
  });
  assertEquals(unknown.status, 400);
  assertEquals(unknown.body.error.code, "unknown_source_ticket");
  assertEquals(unknown.body.error.issues.map((issue: any) => issue.path), ["/source_ticket"]);
});

Deno.test("uma leitura com falha não põe nenhum ingresso na fonte em tipo de ingresso pendente", async () => {
  const day = newWeek();
  const partner = `Meia Parceiro ${run}`;
  const { body } = await read(
    "cinemark-riomar",
    "ingresso_com",
    [movie("a", 9900003)],
    [
      session("a", `${day}T20:00`, { prices: [{ source_ticket: partner, price_cents: 2000 }] }),
    ],
    at(day, "08:00"),
    { status: "error", reason: "A fonte não respondeu." },
  );

  assertEquals(body.result, "failure");
  assertEquals(alertsOf(body.alerts), []);
  const unknown = await resolve({
    source_type: "ingresso_com",
    source_ticket: partner,
    assignment: "half",
  });
  assertEquals(unknown.body.error.code, "unknown_source_ticket");
});

Deno.test("a resolução recusa uma requisição fora do contrato", async () => {
  for (
    const [request, paths] of [
      [{ source_type: "ingresso_com", source_ticket: "MEIA" }, ["/assignment"]],
      [{ source_type: "cinemark", source_ticket: " ", assignment: "student" }, [
        "/source_type",
        "/source_ticket",
        "/assignment",
      ]],
      [{ source_type: "ingresso_com", source_ticket: "MEIA", assignment: "half", extra: 1 }, [
        "/extra",
      ]],
    ] as const
  ) {
    const { status, body } = await resolve(request);
    assertEquals(status, 400, JSON.stringify(request));
    assertEquals(body.error.code, "invalid_request");
    assertEquals(body.error.issues.map((issue: any) => issue.path), paths, JSON.stringify(request));
  }
});
