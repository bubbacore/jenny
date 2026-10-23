import { z } from "zod";
import type { Context } from "./handler.ts";
import { failure, invalidRequest, json } from "./http.ts";
import { sourcePosterUrl, tmdbImagePath } from "./reading-contract.ts";

// The same limit as the images bucket.
const MAX_IMAGE_BYTES = 2 * 1024 * 1024;

const RecordImageRequest = z.strictObject({
  tmdb_path: tmdbImagePath.optional(),
  source_url: sourcePosterUrl.optional(),
  content: z.base64(),
}).superRefine((request, context) => {
  if ((request.tmdb_path === undefined) === (request.source_url === undefined)) {
    context.addIssue({
      code: "custom",
      path: ["tmdb_path"],
      message: "Informe o tmdb_path de uma imagem do TMDB ou o source_url do pôster de um " +
        "filme sem TMDB, só um dos dois.",
    });
  }
});

// Keeps in Storage an image the Hermes downloaded, before the reading that
// cites it: an image from TMDB, known by its path in TMDB, or the poster of a
// movie without TMDB, known by its address in the main source. A new upload of
// the same path or address replaces it.
export async function recordImage(body: unknown, { database, now }: Context): Promise<Response> {
  const parsed = RecordImageRequest.safeParse(body);
  if (!parsed.success) {
    return invalidRequest("A requisição não segue o contrato do registro da imagem.", parsed.error);
  }

  const { tmdb_path, source_url, content } = parsed.data;
  const bytes = Uint8Array.from(atob(content), (character) => character.charCodeAt(0));
  if (bytes.length > MAX_IMAGE_BYTES) {
    return failure(400, "invalid_image", "A imagem passa de 2 MiB.", [
      { path: "/content", message: `A imagem tem ${bytes.length} bytes.` },
    ]);
  }
  const contentType = imageType(bytes);
  if (!contentType) {
    return failure(400, "invalid_image", "O conteúdo não é uma imagem JPEG nem PNG.", [
      {
        path: "/content",
        message: "Envie a imagem baixada, em base64, em JPEG ou PNG. Converta antes um pôster " +
          "em outro formato, como WebP.",
      },
    ]);
  }

  const storagePath = tmdb_path
    ? tmdb_path.slice(1)
    : await sourcePosterStoragePath(source_url!, contentType);
  const uploaded = await database.storage.from("images").upload(storagePath, bytes, {
    contentType,
    upsert: true,
  });
  if (uploaded.error) throw uploaded.error;

  const recorded = {
    storage_path: storagePath,
    content_type: contentType,
    size_bytes: bytes.length,
    reference_time: now.toISOString(),
  };
  const { error } = tmdb_path
    ? await database.rpc("record_image", { tmdb_path, ...recorded })
    : await database.rpc("record_source_poster", { source_url, ...recorded });
  if (error) throw error;

  return json({
    ...(tmdb_path ? { tmdb_path } : { source_url }),
    storage_path: storagePath,
    content_type: contentType,
    size_bytes: bytes.length,
  });
}

function imageType(bytes: Uint8Array): string | null {
  const starts = (signature: number[]) => signature.every((byte, index) => bytes[index] === byte);
  if (starts([0xff, 0xd8, 0xff])) return "image/jpeg";
  if (starts([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) return "image/png";
  return null;
}

// A source poster is stored under a name drawn from its address, flat like the
// TMDB images, because the address itself has slashes and a query.
async function sourcePosterStoragePath(sourceUrl: string, contentType: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(sourceUrl));
  const hex = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0"))
    .join("");
  return `source-${hex}.${contentType === "image/png" ? "png" : "jpg"}`;
}
