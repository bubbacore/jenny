// deno-lint-ignore-file no-explicit-any
import { parse } from "@std/dotenv";

// The local Supabase started by `supabase start`, with the ingestion served by
// `supabase functions serve --env-file supabase/functions/test.env`.
const status = JSON.parse(
  new TextDecoder().decode(
    (await new Deno.Command("supabase", { args: ["status", "-o", "json"] }).output()).stdout,
  ),
);
const testEnv = parse(await Deno.readTextFile("supabase/functions/test.env"));

export const apiUrl: string = status.API_URL;
export const publishableKey: string = status.PUBLISHABLE_KEY;
export const secretKey: string = status.SECRET_KEY;
export const hermesToken: string = testEnv.INGESTION_HERMES_TOKEN;

type CallOptions = { token?: string | null; clock?: string; method?: string };

export async function callIngestion(
  operation: string,
  body: unknown,
  { token = hermesToken, clock, method = "POST" }: CallOptions = {},
): Promise<{ status: number; body: any }> {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (token !== null) headers.authorization = `Bearer ${token}`;
  if (clock) headers["x-ingestion-clock"] = clock;

  const response = await fetch(`${apiUrl}/functions/v1/ingestion/${operation}`, {
    method,
    headers,
    body: method === "GET" ? undefined : JSON.stringify(body),
  });
  return { status: response.status, body: await response.json() };
}

// Reads a view of the site build, with the build's privileged key.
export async function readView(view: string, query = ""): Promise<any[]> {
  const response = await fetch(`${apiUrl}/rest/v1/${view}?${query}`, {
    headers: { apikey: secretKey },
  });
  const body = await response.json();
  if (!response.ok) throw new Error(`${view}: ${JSON.stringify(body)}`);
  return body;
}
