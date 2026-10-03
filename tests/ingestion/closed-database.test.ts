// deno-lint-ignore-file no-explicit-any
import { assert, assertEquals } from "@std/assert";
import { apiUrl, publishableKey, secretKey } from "./local.ts";

// Every table, view and function the Data API exposes, as seen by the
// privileged secret key, with the argument names of each function.
async function exposedPaths(): Promise<Map<string, string[]>> {
  const response = await fetch(`${apiUrl}/rest/v1/`, { headers: { apikey: secretKey } });
  const openapi = await response.json();
  return new Map(
    Object.entries<any>(openapi.paths).filter(([path]) => path !== "/").map(([path, item]) => [
      path,
      Object.keys(
        item.post?.parameters?.find((p: any) => p.in === "body")?.schema?.properties ?? {},
      ),
    ]),
  );
}

Deno.test("a chave publicável não lê nenhuma tabela, visão ou função", async () => {
  const paths = await exposedPaths();
  const tablesAndViews = [
    "/cities",
    "/chains",
    "/cinemas",
    "/sources",
    "/readings",
    "/movies",
    "/sessions",
    "/box_office_prices",
    "/pending_identifications",
    "/resolved_source_titles",
    "/site_cinemas",
    "/site_showtimes",
    "/site_movies",
  ];
  for (const table of tablesAndViews) {
    assert(paths.has(table), `${table} deveria estar na API`);
  }

  // A function is called with all its arguments, so that the refusal comes
  // from the missing privilege and not from an unmatched signature.
  for (const [path, args] of paths) {
    const rpc = path.startsWith("/rpc/");
    const response = await fetch(`${apiUrl}/rest/v1${path}`, {
      method: rpc ? "POST" : "GET",
      headers: { apikey: publishableKey, "content-type": "application/json" },
      body: rpc ? JSON.stringify(Object.fromEntries(args.map((arg) => [arg, null]))) : undefined,
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
