import { z } from "zod";
import type { Context } from "./handler.ts";
import { failure, invalidRequest, json } from "./http.ts";
import { sourceType } from "./reading-contract.ts";

const ResolvePendingTicketTypeRequest = z.strictObject({
  source_type: sourceType,
  source_ticket: z.string().regex(/\S/, { message: "Não pode ficar em branco." }),
  assignment: z.enum(["full", "half", "promo", "not_box_office"]),
});

type Resolved =
  | { alerts: unknown[] }
  | { refusal: { code: "unknown_source_ticket" } };

// Resolves a source ticket of a source type with the ticket type the owner
// assigned, or with not_box_office when it is not a box office price. The
// resolution applies to the kept values of every cinema of the source type,
// with no recollection. Returns the alert that resolves the occurrence.
export async function resolvePendingTicketType(
  body: unknown,
  { database, now }: Context,
): Promise<Response> {
  const parsed = ResolvePendingTicketTypeRequest.safeParse(body);
  if (!parsed.success) {
    return invalidRequest(
      "A requisição não segue o contrato da resolução de tipo de ingresso pendente.",
      parsed.error,
    );
  }

  const { source_type, source_ticket, assignment } = parsed.data;
  const { data, error } = await database.rpc("resolve_pending_ticket_type", {
    source_type,
    source_ticket,
    assignment,
    reference_time: now.toISOString(),
  });
  if (error) throw error;

  const resolved = data as Resolved;
  if (!("refusal" in resolved)) return json(resolved);

  return failure(
    400,
    "unknown_source_ticket",
    "O tipo de fonte nunca teve este ingresso na fonte em tipo de ingresso pendente.",
    [{ path: "/source_ticket", message: `Nenhum ingresso na fonte assim em ${source_type}.` }],
  );
}
