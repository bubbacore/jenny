import { z } from "zod";
import type { Context } from "./handler.ts";
import { failure, invalidRequest, json, pointer } from "./http.ts";
import { slug } from "./reading-contract.ts";

// The daily collection covers every active cinema; a recollection, only the
// cinemas whose reading failed; a manual collection, all or the chosen ones,
// and only it may skip the site publication.
const CollectionPlanRequest = z.strictObject({
  collection_type: z.enum(["daily", "recollection", "manual"]),
  cinemas: z.array(slug).min(1).refine((slugs) => new Set(slugs).size === slugs.length, {
    message: "Cinemas repetidos.",
  }).optional(),
  site_publication: z.boolean().optional(),
}).superRefine((request, context) => {
  if (request.collection_type === "daily" && request.cinemas) {
    context.addIssue({
      code: "custom",
      path: ["cinemas"],
      message: "A coleta diária cobre todos os cinemas ativos.",
    });
  }
  if (request.collection_type === "recollection" && !request.cinemas) {
    context.addIssue({
      code: "custom",
      path: ["cinemas"],
      message: "A recoleta precisa dos cinemas a recoletar.",
    });
  }
  if (request.collection_type !== "manual" && request.site_publication !== undefined) {
    context.addIssue({
      code: "custom",
      path: ["site_publication"],
      message: "Só a coleta avulsa escolhe se termina com uma publicação do site.",
    });
  }
});

// Starts a collection and returns its plan.
export async function collectionPlan(body: unknown, { database, now }: Context): Promise<Response> {
  const parsed = CollectionPlanRequest.safeParse(body);
  if (!parsed.success) {
    return invalidRequest("A requisição não segue o contrato do plano da coleta.", parsed.error);
  }

  const chosen = parsed.data.cinemas ?? null;
  const { data, error } = await database.rpc("collection_plan", {
    cinema_slugs: chosen,
    reference_time: now.toISOString(),
  });
  if (error) throw error;

  const plan = data as { cinemas: { slug: string }[] };
  if (chosen) {
    const planned = new Set(plan.cinemas.map((cinema) => cinema.slug));
    const missing = chosen.flatMap((slug, index) =>
      planned.has(slug) ? [] : [{
        path: pointer(["cinemas", index]),
        message: `Cinema desconhecido ou inativo: ${slug}.`,
      }]
    );
    if (missing.length > 0) {
      return failure(400, "unknown_cinema", "Há cinemas escolhidos fora do plano.", missing);
    }
  }

  const started = await database.rpc("start_collection", {
    collection_type: parsed.data.collection_type,
    cinema_slugs: chosen,
    site_publication_requested: parsed.data.site_publication ?? true,
    reference_time: now.toISOString(),
  });
  if (started.error) throw started.error;

  return json({ collection_id: started.data as string, ...plan });
}
