// Writes contracts/reading.schema.json, the published reading contract, from
// the definition the ingestion validates with.
import { readingJsonSchema } from "../supabase/functions/ingestion/reading-contract.ts";

await Deno.writeTextFile("contracts/reading.schema.json", readingJsonSchema());
