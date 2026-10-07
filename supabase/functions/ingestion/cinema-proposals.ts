import { z } from "zod";
import type { Context } from "./handler.ts";
import { failure, invalidRequest, json } from "./http.ts";
import { slug } from "./reading-contract.ts";

const MAX_INTEGER = 2_147_483_647;

const UpdateCinemaRequest = z.strictObject({
  cinema: slug,
  google_rating: z.strictObject({
    rating: z.number().min(1).max(5).refine(
      (value) => Number.isInteger(Number((value * 10).toFixed(6))),
      { message: "Use no máximo uma casa decimal." },
    ),
    reviews: z.int().positive().max(MAX_INTEGER).optional().describe(
      "A quantidade de avaliações, quando a página do lugar a mostra.",
    ),
  }).optional().describe("A nota do Google, quando o Hermes a leu."),
  proposal: z.strictObject({
    latitude: z.number().min(-90).max(90),
    longitude: z.number().min(-180).max(180),
    google_reviews_url: z.string().regex(/^https:\/\/\S+$/, {
      message: "Use um endereço https.",
    }),
  }).optional().describe("As coordenadas e o link das avaliações do Google propostos."),
}).refine((request) => request.google_rating || request.proposal, {
  message: "Envie a nota do Google, a proposta ou as duas.",
});

const DecideProposalRequest = z.strictObject({
  cinema: slug,
  decision: z.enum(["approve", "reject"]),
});

type Answer =
  | { alerts: unknown[]; proposal?: string }
  | { refusal: { code: "unknown_cinema" | "no_pending_proposal" } };

// Records the weekly Google rating of the cinema and the coordinates and
// Google reviews link the Hermes proposes. The proposal holds only after the
// owner approves it. Returns the alert that opens the proposal occurrence, when
// the proposal is new.
export async function updateCinema(body: unknown, { database, now }: Context): Promise<Response> {
  const parsed = UpdateCinemaRequest.safeParse(body);
  if (!parsed.success) {
    return invalidRequest(
      "A requisição não segue o contrato da atualização do cinema.",
      parsed.error,
    );
  }

  const { cinema, google_rating, proposal } = parsed.data;
  const { data, error } = await database.rpc("update_cinema", {
    cinema_slug: cinema,
    google_rating: google_rating ?? null,
    proposal: proposal ?? null,
    reference_time: now.toISOString(),
  });
  if (error) throw error;

  return answer(data as Answer, cinema);
}

// Approves or rejects the pending proposal of the cinema. Returns the alert
// that resolves the proposal occurrence.
export async function decideProposal(body: unknown, { database, now }: Context): Promise<Response> {
  const parsed = DecideProposalRequest.safeParse(body);
  if (!parsed.success) {
    return invalidRequest(
      "A requisição não segue o contrato da decisão da proposta.",
      parsed.error,
    );
  }

  const { cinema, decision } = parsed.data;
  const { data, error } = await database.rpc("decide_proposal", {
    cinema_slug: cinema,
    decision: decision === "approve" ? "approved" : "rejected",
    reference_time: now.toISOString(),
  });
  if (error) throw error;

  return answer(data as Answer, cinema);
}

function answer(data: Answer, cinema: string): Response {
  if (!("refusal" in data)) return json(data);

  if (data.refusal.code === "unknown_cinema") {
    return failure(400, "unknown_cinema", "Cinema desconhecido.", [
      { path: "/cinema", message: `Nenhum cinema tem o identificador ${cinema}.` },
    ]);
  }
  return failure(400, "no_pending_proposal", "O cinema não tem proposta à espera de decisão.", [
    { path: "/cinema", message: `Nenhuma proposta pendente em ${cinema}.` },
  ]);
}
