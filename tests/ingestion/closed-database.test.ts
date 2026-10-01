import { assert, assertEquals } from "@std/assert";
import { apiUrl, publishableKey, secretKey } from "./local.ts";

// Every table, view and function the Data API exposes, as seen by the
// privileged secret key.
async function exposedPaths(): Promise<string[]> {
  const response = await fetch(`${apiUrl}/rest/v1/`, { headers: { apikey: secretKey } });
  const openapi = await response.json();
  return Object.keys(openapi.paths).filter((path) => path !== "/");
}

Deno.test("a chave publicável não lê nenhuma tabela, visão ou função", async () => {
  const paths = await exposedPaths();
  for (const table of ["/cities", "/chains", "/cinemas", "/sources"]) {
    assert(paths.includes(table), `${table} deveria estar na API`);
  }

  for (const path of paths) {
    const rpc = path.startsWith("/rpc/");
    const response = await fetch(`${apiUrl}/rest/v1${path}`, {
      method: rpc ? "POST" : "GET",
      headers: { apikey: publishableKey, "content-type": "application/json" },
      body: rpc ? "{}" : undefined,
    });
    await response.body?.cancel();
    assert(
      response.status === 401 || response.status === 403,
      `${path} respondeu ${response.status} à chave publicável`,
    );
  }
});

Deno.test("a chave publicável não descobre nada pela API", async () => {
  const response = await fetch(`${apiUrl}/rest/v1/`, { headers: { apikey: publishableKey } });
  const openapi = await response.json();

  assertEquals(Object.keys(openapi.paths ?? {}).filter((path) => path !== "/"), []);
});
