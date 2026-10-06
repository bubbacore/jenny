// deno-lint-ignore-file no-explicit-any
import { assertEquals } from "@std/assert";
import { callIngestion, readView } from "./local.ts";

const CLOCK = "2026-10-12T07:00:00-03:00";

// The cinemas keep their proposals across runs, so each proposal of a run
// has coordinates and a link no other run uses.
const run = crypto.randomUUID().slice(0, 8);
let proposalsTaken = 0;

function newProposal() {
  const offset = Math.floor(Math.random() * 1_000_000) / 1_000_000;
  return {
    latitude: -10.9 - offset,
    longitude: -37.05 - offset,
    google_reviews_url: `https://maps.app.goo.gl/${run}${proposalsTaken++}`,
  };
}

function updateCinema(body: unknown, clock = CLOCK) {
  return callIngestion("update-cinema", body, { clock });
}

function decide(cinema: string, decision: "approve" | "reject") {
  return callIngestion("decide-proposal", { cinema, decision }, { clock: CLOCK });
}

async function siteCinema(cinema: string) {
  const [row] = await readView(
    "site_cinemas",
    `slug=eq.${cinema}&select=latitude,longitude,google_reviews_url,google_rating,google_reviews_count`,
  );
  return row;
}

// The approved place of the cinema, as the build sees it.
async function sitePlace(cinema: string) {
  const { latitude, longitude, google_reviews_url } = await siteCinema(cinema);
  return { latitude, longitude, google_reviews_url };
}

// The place a proposal makes hold, rounded as the database keeps it.
function place(proposal: any) {
  return {
    latitude: Number(proposal.latitude.toFixed(6)),
    longitude: Number(proposal.longitude.toFixed(6)),
    google_reviews_url: proposal.google_reviews_url,
  };
}

// Leaves the cinema with the given values approved and no pending proposal.
async function approve(cinema: string, proposal: any) {
  const updated = await updateCinema({ cinema, proposal });
  assertEquals(updated.status, 200, JSON.stringify(updated.body));
  if (updated.body.proposal === "new") {
    assertEquals((await decide(cinema, "approve")).status, 200);
  }
}

function values(proposal: any) {
  return `as coordenadas ${proposal.latitude.toFixed(6)}, ${proposal.longitude.toFixed(6)} ` +
    `(https://www.google.com/maps?q=${proposal.latitude.toFixed(6)},${
      proposal.longitude.toFixed(6)
    }) e o link das avaliações do Google ${proposal.google_reviews_url}`;
}

Deno.test("a nota do Google de um cinema é atualizada com a data e chega à visão do build", async () => {
  const { status, body } = await updateCinema({
    cinema: "cinesercla-premio",
    google_rating: { rating: 4.4, reviews: 3120 },
  });

  assertEquals(status, 200, JSON.stringify(body));
  assertEquals(body, { alerts: [] });
  const [row] = await readView(
    "cinemas",
    "slug=eq.cinesercla-premio&select=google_rating,google_reviews_count,google_rating_updated_at",
  );
  assertEquals(row, {
    google_rating: 4.4,
    google_reviews_count: 3120,
    google_rating_updated_at: "2026-10-12T10:00:00+00:00",
  });
  const site = await siteCinema("cinesercla-premio");
  assertEquals([site.google_rating, site.google_reviews_count], [4.4, 3120]);
});

Deno.test("uma proposta nova abre a ocorrência da proposta, a mesma proposta de novo não, e ela fica fora das visões até a aprovação", async () => {
  const cinema = "cinemark-riomar";
  const approved = newProposal();
  await approve(cinema, approved);
  const proposal = newProposal();

  const first = await updateCinema({ cinema, proposal });

  assertEquals(first.status, 200, JSON.stringify(first.body));
  assertEquals(first.body, {
    proposal: "new",
    alerts: [{
      type: "proposal",
      subject: "proposal:cinemark-riomar",
      effect: "open",
      text:
        `Cinemark RioMar: o Hermes propôs ${values(proposal)}. Hoje valem ${values(approved)}. ` +
        "Aprove para que a proposta valha no site, ou rejeite para manter o que vale hoje.",
    }],
  });
  assertEquals(await sitePlace(cinema), place(approved));

  const again = await updateCinema({
    cinema,
    google_rating: { rating: 4.6, reviews: 15000 },
    proposal: { ...proposal, latitude: proposal.latitude + 0.0000001 },
  });
  assertEquals(again.body, { proposal: "pending", alerts: [] });

  const same = await updateCinema({ cinema, proposal: approved });
  assertEquals(same.body, { proposal: "approved", alerts: [] });
});

Deno.test("a aprovação faz as coordenadas e o link valerem e resolve a ocorrência", async () => {
  const cinema = "centerplex-parque-shopping";
  const proposal = newProposal();
  await updateCinema({ cinema, proposal });

  const { status, body } = await decide(cinema, "approve");

  assertEquals(status, 200, JSON.stringify(body));
  assertEquals(body, {
    alerts: [{
      type: "proposal",
      subject: "proposal:centerplex-parque-shopping",
      effect: "resolve",
      text: `Centerplex Parque Shopping: proposta aprovada. Passam a valer ${values(proposal)}, ` +
        "a partir da próxima publicação do site.",
    }],
  });
  assertEquals(await sitePlace(cinema), place(proposal));
  assertEquals((await decide(cinema, "approve")).body.error.code, "no_pending_proposal");
});

Deno.test("a rejeição mantém os valores anteriores, resolve a ocorrência e ignora a mesma proposta depois", async () => {
  const cinema = "cinesercla-praia-sul";
  const approved = newProposal();
  await approve(cinema, approved);
  const proposal = newProposal();
  await updateCinema({ cinema, proposal });

  const { status, body } = await decide(cinema, "reject");

  assertEquals(status, 200, JSON.stringify(body));
  assertEquals(body, {
    alerts: [{
      type: "proposal",
      subject: "proposal:cinesercla-praia-sul",
      effect: "resolve",
      text: `Cinesercla Praia Sul: proposta rejeitada. Continuam valendo ${values(approved)}. ` +
        "Se o Hermes propuser o mesmo de novo, a proposta é ignorada.",
    }],
  });
  assertEquals(await sitePlace(cinema), place(approved));

  const again = await updateCinema({ cinema, proposal });
  assertEquals(again.body, { proposal: "rejected", alerts: [] });
});

Deno.test("uma proposta diferente substitui a pendente e alimenta a mesma ocorrência", async () => {
  const cinema = "cinemark-shopping-jardins";
  await updateCinema({ cinema, proposal: newProposal() });
  const replacement = newProposal();

  const { body } = await updateCinema({ cinema, proposal: replacement });
  assertEquals(body.proposal, "new");
  assertEquals(body.alerts.map((alert: any) => [alert.subject, alert.effect]), [
    ["proposal:cinemark-shopping-jardins", "open"],
  ]);

  await decide(cinema, "approve");
  assertEquals(await sitePlace(cinema), place(replacement));
});

Deno.test("a atualização do cinema e a decisão da proposta recusam o que foge do contrato", async () => {
  const empty = await updateCinema({ cinema: "cine-alquimia" });
  assertEquals(empty.status, 400);
  assertEquals(empty.body.error.code, "invalid_request");

  const wrong = await updateCinema({
    cinema: "cine-alquimia",
    google_rating: { rating: 5.5, reviews: 0 },
    proposal: { latitude: -91, longitude: -37, google_reviews_url: "http://maps.app.goo.gl/x" },
  });
  assertEquals(
    wrong.body.error.issues.map((issue: any) => issue.path).sort(),
    [
      "/google_rating/rating",
      "/google_rating/reviews",
      "/proposal/google_reviews_url",
      "/proposal/latitude",
    ],
  );

  const unknown = await updateCinema({ cinema: "cinema-que-nao-existe", proposal: newProposal() });
  assertEquals([unknown.status, unknown.body.error.code], [400, "unknown_cinema"]);

  const decision = await callIngestion("decide-proposal", {
    cinema: "cine-alquimia",
    decision: "maybe",
  });
  assertEquals(decision.body.error.issues.map((issue: any) => issue.path), ["/decision"]);
});
