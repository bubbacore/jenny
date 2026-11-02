import { assert, assertEquals } from "@std/assert";
import { Reading, readingJsonSchema } from "../../supabase/functions/ingestion/reading-contract.ts";

Deno.test("o contrato publicado está em dia com a definição que a ingestão valida", async () => {
  assertEquals(
    await Deno.readTextFile("contracts/reading.schema.json"),
    readingJsonSchema(),
    "Gere o contrato de novo com deno task contract.",
  );
});

function readingOf(source: string, extra: Record<string, unknown>) {
  return { cinema: "cinema-de-teste", source, status: "ok", movies: [], sessions: [], ...extra };
}

const weeklyPost = {
  url: "https://www.instagram.com/p/programacao/",
  published_at: "2026-10-28T10:00:00-03:00",
  period: { first_day: "2026-10-29", last_day: "2026-11-04" },
};

Deno.test("o contrato aceita o post lido e a leitura sem post novo no site oficial e no Instagram", () => {
  for (const source of ["official_site", "instagram"]) {
    for (const extra of [{ post: weeklyPost }, { no_new_post: true }]) {
      const result = Reading.safeParse(readingOf(source, extra));
      assert(result.success, `${source} ${JSON.stringify(result.error?.issues)}`);
    }
  }
});

Deno.test("o contrato recusa uma leitura ok do Instagram sem o post nem a indicação de que não há post novo", () => {
  const result = Reading.safeParse(readingOf("instagram", {}));
  assertEquals(result.error?.issues.map((issue) => issue.path), [["post"]]);
});

Deno.test("o contrato recusa o post e a leitura sem post novo nas fontes que não são de posts", () => {
  for (const source of ["ingresso_com", "veloxtickets", "cinesercla_site"]) {
    for (
      const [extra, path] of [[{ post: weeklyPost }, "post"], [
        { no_new_post: true },
        "no_new_post",
      ]] as const
    ) {
      const result = Reading.safeParse(readingOf(source, extra));
      assertEquals(result.error?.issues.map((issue) => issue.path), [[path]], source);
    }
  }
});
