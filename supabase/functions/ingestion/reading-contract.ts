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

export const sourceType = z.enum([
  "ingresso_com",
  "veloxtickets",
  "cinesercla_site",
  "official_site",
]);

const contentRating = z.enum(["L", "10", "12", "14", "16", "18"]);

// The path of an image in TMDB, like /kqjL17yufvn9OVLyXYpvtyrFfak.jpg.
export const tmdbImagePath = z.string().regex(/^\/[A-Za-z0-9_-]+\.[A-Za-z0-9]+$/);

const imagePath = (description: string) =>
  tmdbImagePath.describe(
    `${description} A imagem precisa ter sido gravada antes com record-image.`,
  );

const Person = z.strictObject({
  tmdb_id: tmdbId,
  name: nonBlank,
  photo_path: imagePath("O caminho da foto no TMDB, com 632 pixels de altura.").optional(),
}).meta({ id: "Person" });

const Genre = z.strictObject({
  tmdb_id: tmdbId,
  name: nonBlank.describe("O nome em português."),
  english_name: nonBlank.describe("O nome em inglês do TMDB, como Science Fiction."),
}).meta({ id: "Genre" });

const Trailer = z.strictObject({
  site: nonBlank.describe("O serviço do vídeo, como YouTube. A ingestão descarta os demais."),
  key: nonBlank.describe("O identificador do vídeo no serviço."),
  language: z.string().regex(/^[a-z]{2}$/).describe("A língua do vídeo no TMDB, como pt."),
  version: z.enum(["subtitled", "dubbed"]).optional().describe(
    "Só num trailer em português, classificado pelo nome do vídeo. Sem indicação, conta como dublado.",
  ),
  official: z.boolean(),
  published_at: z.iso.datetime({ offset: true }),
}).refine((trailer) => trailer.version === undefined || trailer.language === "pt", {
  path: ["version"],
  message: "A versão só vale para um trailer em português.",
}).meta({ id: "Trailer" });

const Tmdb = z.strictObject({
  title: nonBlank.optional().describe("O título no Brasil."),
  original_title: nonBlank.optional(),
  imdb_id: z.string().regex(/^tt\d+$/).optional(),
  overview: nonBlank.optional().describe("A sinopse em português."),
  year: z.int().min(1870).max(2100).optional(),
  countries: z.array(z.string().regex(/^[A-Z]{2}$/)).optional().describe(
    "Os países de produção, em ISO 3166-1, como BR.",
  ),
  original_language: z.string().regex(/^[a-z]{2}$/).optional().describe(
    "A língua original, em ISO 639-1, como pt.",
  ),
  genres: z.array(Genre).optional(),
  runtime: z.int().positive().max(32_767).optional().describe("A duração em minutos."),
  budget: z.int().nonnegative().optional().describe(
    "O orçamento em dólares, como o TMDB o informa. O zero do TMDB é gravado como ausente.",
  ),
  revenue: z.int().nonnegative().optional().describe(
    "A receita em dólares, como o TMDB a informa. O zero do TMDB é gravado como ausente.",
  ),
  content_rating: contentRating.optional().describe(
    "A certificação do Brasil nas datas de lançamento do TMDB.",
  ),
  poster_path: imagePath("O caminho do pôster no TMDB, com 500 pixels de largura.").optional(),
  trailers: z.array(Trailer).optional().describe(
    "Os trailers do TMDB. A ingestão escolhe um só, do YouTube.",
  ),
  credits: z.strictObject({
    cast: z.array(z.strictObject({
      person: Person,
      character: nonBlank.optional(),
      order: z.int().nonnegative().max(MAX_INTEGER).describe("A ordem no elenco do TMDB."),
    })).describe("O elenco. A ingestão guarda os cinco primeiros pela ordem."),
    directors: z.array(z.strictObject({ person: Person })),
  }).optional(),
}).meta({ id: "Tmdb" });

const Movie = z.strictObject({
  key: nonBlank.describe("Chave do filme dentro da leitura, citada pelas sessões."),
  source_title: nonBlank.describe("O título na fonte, como a fonte principal o publica."),
  tmdb_id: tmdbId.describe("O identificador do TMDB proposto pelo Hermes."),
  tmdb_search_top_id: tmdbId.nullable().describe(
    "O primeiro resultado da busca no TMDB por título e ano, ou null sem resultado.",
  ),
  content_rating: contentRating.optional().describe(
    "A classificação indicativa normalizada. Fica ausente quando a fonte não a publica ou publica outro valor.",
  ),
  overview: nonBlank.optional().describe("A sinopse, quando a fonte principal a publica."),
  trailer: z.strictObject({
    url: z.url().describe(
      "O endereço do vídeo. A ingestão descarta o que não for do YouTube.",
    ),
    version: z.enum(["subtitled", "dubbed", "original"]).optional().describe(
      "A versão, quando a fonte a indica. Sem ela, o trailer conta como dublado.",
    ),
  }).optional().describe("O trailer, quando a fonte principal o publica."),
  tmdb: Tmdb.optional().describe(
    "Os metadados do TMDB, com os créditos e os caminhos das imagens. Um filme novo traz todos " +
      "os que o TMDB tem; um filme conhecido, só os que o plano apontou como faltantes. " +
      "Num filme conhecido, a ingestão ignora os demais.",
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

const Post = z.strictObject({
  url: z.url().describe("O link do post."),
  published_at: z.iso.datetime({ offset: true }).describe("A data de publicação do post."),
}).meta({ id: "Post" });

const common = {
  cinema: slug,
  source: sourceType,
  movies: z.array(Movie),
  sessions: z.array(Session),
};

const reason = nonBlank.describe("O motivo da falha.");

export const Reading = z.discriminatedUnion("status", [
  z.strictObject({
    ...common,
    status: z.literal("ok"),
    post: Post.optional().describe(
      "O post lido, numa leitura do site oficial com post novo. A fonte do post é a da leitura.",
    ),
    no_new_post: z.literal(true).optional().describe(
      "Indica, numa leitura do site oficial, que não há post novo. A leitura vai sem filmes nem " +
        "sessões, e a ingestão reaproveita a programação do último post lido.",
    ),
  }),
  z.strictObject({ ...common, status: z.literal("error"), reason }),
  z.strictObject({ ...common, status: z.literal("incomplete"), reason }),
]).superRefine(checkReferences).superRefine(checkPost).meta({
  title: "Leitura",
  description: "A programação completa de um cinema na janela, lida da fonte principal. " +
    "Além do schema, a ingestão recusa: chaves de filme repetidas, sessões que citam um filme " +
    "fora da leitura, sessões repetidas (mesmo filme do TMDB, início, sala, idioma e formato), " +
    "marcadores de sala repetidos, ingressos na fonte repetidos na mesma sessão e datas inexistentes. " +
    "Recusa também uma leitura ok do site oficial sem o post nem no_new_post, ou com os dois, " +
    "um post ou no_new_post numa leitura de outra fonte e uma leitura sem post novo com filmes " +
    "ou sessões.",
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

type PostShape = ReadingShape & {
  status: string;
  source: string;
  post?: z.infer<typeof Post>;
  no_new_post?: true;
};

// Every successful reading of the official site reads a post or says there is
// no new post, and only it does.
function checkPost(reading: PostShape, context: z.RefinementCtx) {
  if (reading.status !== "ok") return;

  const { post, no_new_post } = reading;
  if (reading.source !== "official_site") {
    if (post) {
      context.addIssue({
        code: "custom",
        path: ["post"],
        message: "Só uma leitura do site oficial traz um post.",
      });
    }
    if (no_new_post) {
      context.addIssue({
        code: "custom",
        path: ["no_new_post"],
        message: "Só uma leitura do site oficial indica que não há post novo.",
      });
    }
    return;
  }

  if (!post && !no_new_post) {
    context.addIssue({
      code: "custom",
      path: ["post"],
      message:
        "Uma leitura do site oficial traz o post lido ou a indicação de que não há post novo.",
    });
  }
  if (post && no_new_post) {
    context.addIssue({
      code: "custom",
      path: ["no_new_post"],
      message: "Uma leitura com o post lido não indica que não há post novo.",
    });
  }
  if (no_new_post && reading.movies.length > 0) {
    context.addIssue({
      code: "custom",
      path: ["movies"],
      message: "Uma leitura sem post novo vai sem filmes.",
    });
  }
  if (no_new_post && reading.sessions.length > 0) {
    context.addIssue({
      code: "custom",
      path: ["sessions"],
      message: "Uma leitura sem post novo vai sem sessões.",
    });
  }
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
