import { z } from "zod";

z.config(z.locales.pt());

// The reading contract: the one definition shared by the ingestion and the
// Hermes reading tools. contracts/reading.schema.json is generated from it.

const MAX_INTEGER = 2_147_483_647;

const nonBlank = z.string().regex(/\S/, { message: "Não pode ficar em branco." });
export const slug = z.string().regex(/^[a-z0-9]+(-[a-z0-9]+)*$/);
const tmdbId = z.int().positive().max(MAX_INTEGER);

// Local time in the cinema's city, without seconds or offset.
const localDateTime = z.string()
  .regex(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/, { abort: true })
  .refine(isRealDateTime, { message: "Data ou hora inexistente." });

const Movie = z.strictObject({
  key: nonBlank.describe("Chave do filme dentro da leitura, citada pelas sessões."),
  source_title: nonBlank.describe("O título na fonte, como a fonte principal o publica."),
  tmdb_id: tmdbId.describe("O identificador do TMDB proposto pelo Hermes."),
  tmdb_search_top_id: tmdbId.nullable().describe(
    "O primeiro resultado da busca no TMDB por título e ano, ou null sem resultado.",
  ),
  content_rating: z.enum(["L", "10", "12", "14", "16", "18"]).optional().describe(
    "A classificação indicativa normalizada. Fica ausente quando a fonte não a publica ou publica outro valor.",
  ),
  tmdb: z.strictObject({
    title: nonBlank.optional().describe("O título no Brasil."),
    original_title: nonBlank.optional(),
  }).optional().describe(
    "Os metadados do TMDB. Um filme novo traz todos; um filme conhecido, só os que o plano apontou como faltantes.",
  ),
}).meta({ id: "Movie" });

const Price = z.strictObject({
  source_ticket: nonBlank.describe("O ingresso na fonte, como a fonte o chama."),
  kind: z.enum(["full", "half", "promo"]).optional().describe(
    "O tipo de ingresso, só quando a fonte o informa de forma estruturada.",
  ),
  price_cents: z.int().positive().max(MAX_INTEGER).describe(
    "O preço de bilheteria em centavos, sem a taxa de conveniência.",
  ),
}).meta({ id: "Price" });

const Session = z.strictObject({
  movie_key: nonBlank,
  starts_at: localDateTime.describe("O início, no horário local da cidade, como 2026-09-24T17:00."),
  room: nonBlank.optional(),
  audio: z.enum(["dubbed", "subtitled", "original"]).optional(),
  format: z.enum(["2d", "3d", "imax"]).optional(),
  tags: z.array(nonBlank).describe("Os marcadores de sala, como VIP, XD ou D-BOX."),
  external_id: nonBlank.optional().describe("O identificador da sessão na fonte."),
  prices: z.array(Price).describe("Vazio quando o preço de bilheteria não pôde ser determinado."),
}).meta({ id: "Session" });

const common = {
  cinema: slug,
  source: z.enum(["ingresso_com", "veloxtickets", "cinesercla_site", "official_site"]),
  movies: z.array(Movie),
  sessions: z.array(Session),
};

const reason = nonBlank.describe("O motivo da falha.");

export const Reading = z.discriminatedUnion("status", [
  z.strictObject({ ...common, status: z.literal("ok") }),
  z.strictObject({ ...common, status: z.literal("error"), reason }),
  z.strictObject({ ...common, status: z.literal("incomplete"), reason }),
]).superRefine(checkReferences).meta({
  title: "Leitura",
  description: "A programação completa de um cinema na janela, lida da fonte principal. " +
    "Além do schema, a ingestão recusa: chaves de filme repetidas, sessões que citam um filme " +
    "fora da leitura, sessões repetidas (mesmo filme do TMDB, início, sala, idioma e formato), " +
    "marcadores de sala repetidos, ingressos na fonte repetidos na mesma sessão e datas inexistentes.",
});

export type Reading = z.infer<typeof Reading>;

export function readingJsonSchema(): string {
  return JSON.stringify(z.toJSONSchema(Reading, { target: "draft-2020-12" }), null, 2) + "\n";
}

function isRealDateTime(value: string): boolean {
  const [date, time] = value.split("T");
  const [year, month, day] = date.split("-").map(Number);
  const [hour, minute] = time.split(":").map(Number);
  const parsed = new Date(Date.UTC(year, month - 1, day, hour, minute));
  return parsed.getUTCFullYear() === year && parsed.getUTCMonth() === month - 1 &&
    parsed.getUTCDate() === day && parsed.getUTCHours() === hour &&
    parsed.getUTCMinutes() === minute;
}

type ReadingShape = {
  movies: z.infer<typeof Movie>[];
  sessions: z.infer<typeof Session>[];
};

function checkReferences(reading: ReadingShape, context: z.RefinementCtx) {
  const movies = new Map<string, number>();
  reading.movies.forEach((movie, index) => {
    if (movies.has(movie.key)) {
      context.addIssue({
        code: "custom",
        path: ["movies", index, "key"],
        message: `Chave repetida: a mesma do filme ${movies.get(movie.key)}.`,
      });
    } else {
      movies.set(movie.key, index);
    }
  });

  const sessions = new Map<string, number>();
  reading.sessions.forEach((session, index) => {
    const movieIndex = movies.get(session.movie_key);
    if (movieIndex === undefined) {
      context.addIssue({
        code: "custom",
        path: ["sessions", index, "movie_key"],
        message: "Nenhum filme da leitura tem esta chave.",
      });
    } else {
      const identity = JSON.stringify([
        reading.movies[movieIndex].tmdb_id,
        session.starts_at,
        session.room ?? null,
        session.audio ?? null,
        session.format ?? null,
      ]);
      if (sessions.has(identity)) {
        context.addIssue({
          code: "custom",
          path: ["sessions", index],
          message: `Sessão repetida: mesmo filme, início, sala, idioma e formato da sessão ${
            sessions.get(identity)
          }.`,
        });
      } else {
        sessions.set(identity, index);
      }
    }

    repeated(session.tags).forEach((tagIndex) =>
      context.addIssue({
        code: "custom",
        path: ["sessions", index, "tags", tagIndex],
        message: "Marcador de sala repetido.",
      })
    );
    repeated(session.prices.map((price) => price.source_ticket)).forEach((priceIndex) =>
      context.addIssue({
        code: "custom",
        path: ["sessions", index, "prices", priceIndex, "source_ticket"],
        message: "Ingresso na fonte repetido na mesma sessão.",
      })
    );
  });
}

// The indexes of the values already seen earlier in the list.
function repeated(values: string[]): number[] {
  const seen = new Set<string>();
  return values.flatMap((value, index) => {
    if (seen.has(value)) return [index];
    seen.add(value);
    return [];
  });
}
