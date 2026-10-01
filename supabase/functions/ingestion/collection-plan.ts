import { z } from "zod";
import type { Context } from "./handler.ts";
import { failure, json, pointer } from "./http.ts";

z.config(z.locales.pt());

const slug = z.string().regex(/^[a-z0-9]+(-[a-z0-9]+)*$/);

const CollectionPlanRequest = z.strictObject({
  collection_type: z.enum(["daily", "recollection", "manual"]),
  cinemas: z.array(slug).min(1).refine((slugs) => new Set(slugs).size === slugs.length, {
    message: "Cinemas repetidos.",
  }).optional(),
});

export async function collectionPlan(body: unknown, { database, now }: Context): Promise<Response> {
  const parsed = CollectionPlanRequest.safeParse(body);
  if (!parsed.success) {
    return failure(
      400,
      "invalid_request",
      "A requisição não segue o contrato do plano da coleta.",
      parsed.error.issues.flatMap((issue) =>
        issue.code === "unrecognized_keys"
          ? issue.keys.map((key) => ({
            path: pointer([...issue.path, key]),
            message: "Campo desconhecido.",
          }))
          : [{ path: pointer(issue.path), message: issue.message }]
      ),
    );
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

  return json(plan);
}
