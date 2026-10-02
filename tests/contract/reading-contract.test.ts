import { assertEquals } from "@std/assert";
import { readingJsonSchema } from "../../supabase/functions/ingestion/reading-contract.ts";

Deno.test("o contrato publicado está em dia com a definição que a ingestão valida", async () => {
  assertEquals(
    await Deno.readTextFile("contracts/reading.schema.json"),
    readingJsonSchema(),
    "Gere o contrato de novo com deno task contract.",
  );
});
