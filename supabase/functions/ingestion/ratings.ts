import { z } from "zod";
import type { Context } from "./handler.ts";
import { failure, invalidRequest, json, pointer } from "./http.ts";

const MAX_INTEGER = 2_147_483_647;

// A rating with at most one decimal place, like IMDb's 7.3.
const oneDecimal = (min: number, max: number) =>
  z.number().min(min).max(max).refine(
    (value) => Number.isInteger(Number((value * 10).toFixed(6))),
    {
      message: "Use no máximo uma casa decimal.",
    },
  );

const rottenTomatoesUrl = z.url({
  protocol: /^https$/,
  hostname: /^www\.rottentomatoes\.com$/,
  message: "Use um link https do site do Rotten Tomatoes, em www.rottentomatoes.com.",
});

// The movie page on the Rotten Tomatoes site, under /m/, or the site search,
// under /search, so that the next update knows whether to read the page or
// to search again.
const RottenTomatoesLink = z.strictObject({
  url: rottenTomatoesUrl,
  kind: z.enum(["movie_page", "search"]),
}).superRefine((link, context) => {
  // A wrong url is already reported, and the refinement still runs after it.
  if (!rottenTomatoesUrl.safeParse(link.url).success) return;
  const path = new URL(link.url).pathname;
  if (link.kind === "movie_page" && !path.startsWith("/m/")) {
    context.addIssue({
      code: "custom",
      path: ["url"],
      message: "A página do filme no Rotten Tomatoes fica em /m/.",
    });
  }
  if (link.kind === "search" && path !== "/search") {
    context.addIssue({
      code: "custom",
      path: ["url"],
      message: "A busca do Rotten Tomatoes fica em /search.",
    });
  }
});

// The Tomatometer with its origin and whether Rotten Tomatoes gave the movie
// Certified Fresh. Only the movie page on the Rotten Tomatoes site shows the
// seal, so a Tomatometer from OMDb never has it. Without the field, as the
// Hermes sent it before the seal, the movie counts as without it.
const Tomatometer = z.strictObject({
  score: z.int().min(0).max(100),
  source: z.enum(["omdb", "rotten_tomatoes_site"]),
  certified_fresh: z.boolean().optional().describe(
    "Se o Rotten Tomatoes deu o Certified Fresh ao filme, lido da página do filme no site dele. " +
      "Sem o campo, o filme fica sem o Certified Fresh.",
  ),
}).superRefine((tomatometer, context) => {
  if (tomatometer.source === "omdb" && tomatometer.certified_fresh) {
    context.addIssue({
      code: "custom",
      path: ["certified_fresh"],
      message: "O OMDb não informa o Certified Fresh. Ele vem só do site do Rotten Tomatoes.",
    });
  }
});

const RatingsPlanRequest = z.strictObject({ collection_id: z.uuid() });

const UpdateRatingsRequest = z.strictObject({
  collection_id: z.uuid().optional().describe(
    "A coleta da atualização. Sem ela, a atualização não afeta nenhuma publicação do site.",
  ),
  movies: z.array(z.strictObject({
    tmdb_id: z.int().positive().max(MAX_INTEGER),
    imdb: z.strictObject({
      rating: oneDecimal(1, 10),
      votes: z.int().positive().max(MAX_INTEGER),
    }).nullable().describe("A nota do IMDb com os votos, ou null quando o filme não tem nota."),
    tomatometer: Tomatometer.nullable().describe(
      "O Tomatometer com a origem e o Certified Fresh, ou null quando o filme não tem.",
    ),
    rotten_tomatoes_link: RottenTomatoesLink.nullable().optional().describe(
      "O link do Rotten Tomatoes, que é a página do filme ou a busca do site, ou null para " +
        "apagar o guardado. Só a atualização sem coleta pode omiti-lo, e o guardado fica.",
    ),
  })).min(1),
}).superRefine((request, context) => {
  const seen = new Set<number>();
  request.movies.forEach((movie, index) => {
    if (seen.has(movie.tmdb_id)) {
      context.addIssue({
        code: "custom",
        path: ["movies", index, "tmdb_id"],
        message: "Filme repetido.",
      });
    }
    seen.add(movie.tmdb_id);
    if (request.collection_id && movie.rotten_tomatoes_link === undefined) {
      context.addIssue({
        code: "custom",
        path: ["movies", index, "rotten_tomatoes_link"],
        message: "Envie o link do Rotten Tomatoes, ou null sem ele.",
      });
    }
  });
});

type CollectionRefusal = { code: "unknown_collection" | "collection_finished" };

type Planned = { movies: unknown[] } | { refusal: CollectionRefusal };

type Updated =
  | { updated_movies: number }
  | { refusal: CollectionRefusal | { code: "unknown_movie"; indexes: number[] } };

// Returns the movies whose ratings the collection updates before its end: the
// ones with sessions in active cinemas and an IMDb id, not updated today, each
// with the stored Rotten Tomatoes link the Hermes reads first.
export async function ratingsPlan(body: unknown, { database, now }: Context): Promise<Response> {
  const parsed = RatingsPlanRequest.safeParse(body);
  if (!parsed.success) {
    return invalidRequest("A requisição não segue o contrato do plano das notas.", parsed.error);
  }

  const { data, error } = await database.rpc("ratings_plan", {
    collection_id: parsed.data.collection_id,
    reference_time: now.toISOString(),
  });
  if (error) throw error;

  const planned = data as Planned;
  if (!("refusal" in planned)) return json(planned);
  return collectionRefusal(planned.refusal);
}

// Records the IMDb and Rotten Tomatoes ratings of the movies, with Certified
// Fresh, and their Rotten Tomatoes link, with the date of the update. A null
// rating or link means the movie has none, and replaces what was kept; a null
// Tomatometer also erases Certified Fresh. Inside a collection, a changed
// rating, Certified Fresh or link makes a recollection end with a site
// publication.
export async function updateRatings(body: unknown, { database, now }: Context): Promise<Response> {
  const parsed = UpdateRatingsRequest.safeParse(body);
  if (!parsed.success) {
    return invalidRequest(
      "A requisição não segue o contrato da atualização de notas.",
      parsed.error,
    );
  }

  const { data, error } = await database.rpc("update_ratings", {
    movies: parsed.data.movies,
    collection_id: parsed.data.collection_id ?? null,
    reference_time: now.toISOString(),
  });
  if (error) throw error;

  const updated = data as Updated;
  if (!("refusal" in updated)) return json(updated);

  const { refusal } = updated;
  if (refusal.code !== "unknown_movie") return collectionRefusal(refusal);
  return failure(
    400,
    "unknown_movie",
    "Há filmes fora do acervo.",
    refusal.indexes.map((index) => ({
      path: pointer(["movies", index, "tmdb_id"]),
      message: "Nenhum filme do acervo tem este identificador do TMDB.",
    })),
  );
}

function collectionRefusal(refusal: CollectionRefusal): Response {
  if (refusal.code === "unknown_collection") {
    return failure(400, "unknown_collection", "A coleta não foi iniciada.", [
      { path: "/collection_id", message: "Nenhuma coleta tem este identificador." },
    ]);
  }
  return failure(409, "collection_finished", "Esta coleta já terminou.");
}
