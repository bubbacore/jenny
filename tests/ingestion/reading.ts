import { assertEquals } from "@std/assert";
import { callIngestion, readView } from "./local.ts";

// Monday in Aracaju. The window runs from 2026-10-05 to 2026-10-11.
export const MONDAY_NOON = "2026-10-05T12:00:00-03:00";
export const RELEASE = "v0.1.0";

// Tests that depend on a cinema's history, or on every cinema's, run each in
// its own week, picked at random on every run and far from the fixed dates of
// the other tests. The history in that week is then only what the test
// records, and the results do not depend on earlier runs. The first reading
// of a cinema in the week may still close something left by another run, so
// its alerts are not checked.
const runBlock = Math.floor(Math.random() * 1_000);
let weeksTaken = 0;

// The Monday of a week no other test of this run uses.
export function newWeek(): string {
  return addDays("2027-01-04", 7 * (runBlock * 100 + weeksTaken++));
}

// The catalog is shared by every run, so each run draws its own TMDB ids, far
// from the fixed ids of the other tests. They also name the images.
const tmdbIdBase = 1_000_000_000 + Math.floor(Math.random() * 10_000_000) * 100;
let tmdbIdsTaken = 0;

export function newTmdbId(): number {
  return tmdbIdBase + tmdbIdsTaken++;
}

export function addDays(date: string, days: number): string {
  const day = new Date(`${date}T00:00:00Z`);
  day.setUTCDate(day.getUTCDate() + days);
  return day.toISOString().slice(0, 10);
}

// A time in the cities of v1, which are always at UTC-3.
export function at(date: string, time: string): string {
  return `${date}T${time}:00-03:00`;
}

export function window(date: string): string[] {
  return [0, 1, 2, 3, 4, 5, 6].map((day) => addDays(date, day));
}

export function dayMonth(date: string): string {
  return `${date.slice(8, 10)}/${date.slice(5, 7)}`;
}

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

// A post of its own, with a link no other run uses.
let postsTaken = 0;

export function post(publishedAt = "2026-10-01T10:00:00-03:00") {
  return {
    url: `https://cinemadocentro.com.br/confira-a-programacao-${runBlock}-${postsTaken++}/`,
    published_at: publishedAt,
  };
}

// A successful reading of the official site reads a post, which is a new one
// unless the test brings its own post or says there is no new post.
export function reading(
  cinema: string,
  source: string,
  movies: unknown[],
  sessions: unknown[],
  extra: Record<string, unknown> = {},
) {
  const readsPost = source === "official_site" && (extra.status ?? "ok") === "ok" &&
    !("post" in extra) && !("no_new_post" in extra);
  return {
    cinema,
    source,
    status: "ok",
    movies,
    sessions,
    ...(readsPost ? { post: post() } : {}),
    ...extra,
  };
}

// Starts a collection and returns its id.
export async function collect(
  collectionType: "daily" | "recollection" | "manual",
  clock = MONDAY_NOON,
  extra: Record<string, unknown> = {},
): Promise<string> {
  const { status, body } = await callIngestion(
    "collection-plan",
    { collection_type: collectionType, ...extra },
    { clock },
  );
  assertEquals(status, 200, JSON.stringify(body));
  return body.collection_id;
}

export function finish(collectionId: string, clock = MONDAY_NOON) {
  return callIngestion("finish-collection", { collection_id: collectionId }, { clock });
}

// Reserves the cinema inside the given collection or, without one, inside a
// new manual collection of every active cinema.
export async function start(cinema: string, clock = MONDAY_NOON, collectionId?: string) {
  const collection_id = collectionId ?? await collect("manual", clock);
  return callIngestion("start-reading", { collection_id, cinema }, { clock });
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
  collectionId?: string,
) {
  const started = await start(cinema, clock, collectionId);
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
