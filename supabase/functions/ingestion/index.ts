import { createClient } from "@supabase/supabase-js";
import { handle } from "./handler.ts";

const secretKeys = Deno.env.get("SUPABASE_SECRET_KEYS");
const database = createClient(
  Deno.env.get("SUPABASE_URL")!,
  secretKeys ? JSON.parse(secretKeys).default : Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false, autoRefreshToken: false } },
);

Deno.serve((request) =>
  handle(request, {
    database,
    hermesToken: Deno.env.get("INGESTION_HERMES_TOKEN"),
    clockOverride: Deno.env.get("INGESTION_CLOCK_OVERRIDE") === "allowed",
  })
);
