// Compares the bearer token with the expected one without leaking, by timing,
// how much of it matched.
export async function hasToken(request: Request, expected: string): Promise<boolean> {
  const header = request.headers.get("authorization") ?? "";
  const match = /^Bearer (.+)$/.exec(header);
  if (!match) return false;

  const [given, wanted] = await Promise.all([digest(match[1]), digest(expected)]);
  let difference = 0;
  for (let index = 0; index < wanted.length; index++) difference |= given[index] ^ wanted[index];
  return difference === 0;
}

async function digest(value: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
}
