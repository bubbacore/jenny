import type { z } from "zod";

export type Issue = { path: string; message: string };

export function json(body: unknown, status = 200): Response {
  return Response.json(body, { status });
}

export function failure(status: number, code: string, message: string, issues?: Issue[]): Response {
  return json({ error: { code, message, ...(issues ? { issues } : {}) } }, status);
}

export function invalidRequest(message: string, error: z.ZodError): Response {
  return failure(400, "invalid_request", message, contractIssues(error));
}

// Paths are JSON Pointers into the request body, like /cinemas/0.
export function pointer(path: readonly PropertyKey[]): string {
  return path.map((segment) => "/" + String(segment).replaceAll("~", "~0").replaceAll("/", "~1"))
    .join("");
}

// One issue per wrong field, with an unknown field reported at its own path.
function contractIssues(error: z.ZodError): Issue[] {
  return error.issues.flatMap((issue) =>
    issue.code === "unrecognized_keys"
      ? issue.keys.map((key) => ({
        path: pointer([...issue.path, key]),
        message: "Campo desconhecido.",
      }))
      : [{ path: pointer(issue.path), message: issue.message }]
  );
}
