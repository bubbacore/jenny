import { assertEquals } from "@std/assert";
import { callIngestion, readView } from "./local.ts";

// Monday in Aracaju. The window runs from 2026-10-05 to 2026-10-11.
export const MONDAY_NOON = "2026-10-05T12:00:00-03:00";
export const RELEASE = "v0.1.0";

export function movie(key: string, tmdbId: number, extra: Record<string, unknown> = {}) {
  return {
    key,
    source_title: `Filme ${key}`,
    tmdb_id: tmdbId,
    tmdb_search_top_id: tmdbId,
    tmdb: { title: `Filme ${tmdbId}`, original_title: `Movie ${tmdbId}` },
    ...extra,
  };
}

export function session(movieKey: string, startsAt: string, extra: Record<string, unknown> = {}) {
  return {
    movie_key: movieKey,
    starts_at: startsAt,
    room: "Sala 1",
    audio: "dubbed",
    format: "2d",
    tags: [],
    prices: [],
    ...extra,
  };
}

export function reading(
  cinema: string,
  source: string,
  movies: unknown[],
  sessions: unknown[],
  extra: Record<string, unknown> = {},
) {
  return { cinema, source, status: "ok", movies, sessions, ...extra };
}

export function start(cinema: string, clock = MONDAY_NOON) {
  return callIngestion("start-reading", { cinema }, { clock });
}

export function record(readingId: string, body: unknown, clock = MONDAY_NOON, release = RELEASE) {
  return callIngestion(
    "record-reading",
    { reading_id: readingId, collection_release: release, reading: body },
    { clock },
  );
}

// Reserves the cinema and records the reading at the same time.
export async function read(
  cinema: string,
  source: string,
  movies: unknown[],
  sessions: unknown[],
  clock = MONDAY_NOON,
  extra: Record<string, unknown> = {},
) {
  const started = await start(cinema, clock);
  assertEquals(started.status, 201, JSON.stringify(started.body));
  return record(started.body.reading_id, reading(cinema, source, movies, sessions, extra), clock);
}

export function showtimes(cinema: string) {
  return readView("site_showtimes", `cinema=eq.${cinema}&order=starts_at,movie,room`);
}

// The state of each day of the cinema's window, as the build sees it at the
// given time.
export async function cinemaDays(cinema: string, clock: string): Promise<[string, string][]> {
  const days = await readView(
    "rpc/site_cinema_days",
    `reference_time=${encodeURIComponent(clock)}&cinema=eq.${cinema}`,
  );
  return days.map((day) => [day.date, day.state]);
}
