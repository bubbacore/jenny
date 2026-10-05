import { z } from "zod";
import type { Context } from "./handler.ts";
import { failure, invalidRequest, json } from "./http.ts";
import { tmdbImagePath } from "./reading-contract.ts";

// The same limit as the images bucket.
const MAX_IMAGE_BYTES = 2 * 1024 * 1024;

const RecordImageRequest = z.strictObject({
  tmdb_path: tmdbImagePath,
  content: z.base64(),
});

// Keeps in Storage an image the Hermes downloaded from TMDB, before the
// reading that cites it. The image is known by its path in TMDB, and a new
// upload of the same path replaces it.
export async function recordImage(body: unknown, { database, now }: Context): Promise<Response> {
  const parsed = RecordImageRequest.safeParse(body);
  if (!parsed.success) {
    return invalidRequest("A requisição não segue o contrato do registro da imagem.", parsed.error);
  }

  const { tmdb_path, content } = parsed.data;
  const bytes = Uint8Array.from(atob(content), (character) => character.charCodeAt(0));
  if (bytes.length > MAX_IMAGE_BYTES) {
    return failure(400, "invalid_image", "A imagem passa de 2 MiB.", [
      { path: "/content", message: `A imagem tem ${bytes.length} bytes.` },
    ]);
  }
  const contentType = imageType(bytes);
  if (!contentType) {
    return failure(400, "invalid_image", "O conteúdo não é uma imagem JPEG nem PNG.", [
      { path: "/content", message: "Envie a imagem baixada do TMDB, em base64." },
    ]);
  }

  const storagePath = tmdb_path.slice(1);
  const uploaded = await database.storage.from("images").upload(storagePath, bytes, {
    contentType,
    upsert: true,
  });
  if (uploaded.error) throw uploaded.error;

  const { error } = await database.rpc("record_image", {
    tmdb_path,
    storage_path: storagePath,
    content_type: contentType,
    size_bytes: bytes.length,
    reference_time: now.toISOString(),
  });
  if (error) throw error;

  return json({
    tmdb_path,
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
