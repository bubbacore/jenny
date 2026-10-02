export type Issue = { path: string; message: string };

export function json(body: unknown, status = 200): Response {
  return Response.json(body, { status });
}

export function failure(status: number, code: string, message: string, issues?: Issue[]): Response {
  return json({ error: { code, message, ...(issues ? { issues } : {}) } }, status);
}

// Paths are JSON Pointers into the request body, like /cinemas/0.
export function pointer(path: readonly PropertyKey[]): string {
  return path.map((segment) => "/" + String(segment).replaceAll("~", "~0").replaceAll("/", "~1"))
    .join("");
}
