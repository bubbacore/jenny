// deno-lint-ignore-file no-explicit-any
import { assert, assertEquals } from "@std/assert";
import { apiUrl, callIngestion, hermesToken, publishableKey, secretKey } from "./local.ts";

const plan = (body: unknown, options?: Parameters<typeof callIngestion>[2]) =>
  callIngestion("collection-plan", body, options);

Deno.test("o plano da coleta devolve os 7 cinemas da v1 com as configurações da spec", async () => {
  const { status, body } = await plan({ collection_type: "daily" });

  assertEquals(status, 200);
  assertEquals(
    body.cinemas.map((cinema: any) => [cinema.slug, cinema.city, cinema.source]),
    [
      ["centerplex-parque-shopping", "aracaju", {
        type: "veloxtickets",
        config: {
          url:
            "https://www.veloxtickets.com/Parceiro/P-centerplex/Local/Cinema/Aracaju/Centerplex-Parque-Shopping-Aracaju/ARC",
        },
      }],
      ["cine-alquimia", "aracaju", {
        type: "ingresso_com",
        config: { theater_id: 1602, city_id: 4 },
      }],
      ["cinema-do-centro", "aracaju", {
        type: "official_site",
        config: {
          url: "https://cinemadocentro.com.br/",
          wordpress_category_id: 3,
          post_title_prefix: "Confira a programação",
        },
      }],
      ["cinemark-riomar", "aracaju", {
        type: "ingresso_com",
        config: { theater_id: 762, city_id: 4 },
      }],
      ["cinemark-shopping-jardins", "aracaju", {
        type: "ingresso_com",
        config: { theater_id: 313, city_id: 4 },
      }],
      ["cinesercla-praia-sul", "aracaju", {
        type: "cinesercla_site",
        config: { unit_slug: "praia-sul", ingresso_plus_group: "PRAIASUL" },
      }],
      ["cinesercla-premio", "nossa-senhora-do-socorro", {
        type: "cinesercla_site",
        config: { unit_slug: "nossa-senhora-do-socorro", ingresso_plus_group: "CINESERCLAPREMI" },
      }],
    ],
  );
});

Deno.test("o plano da coleta traz os dias sem funcionamento de cada cinema", async () => {
  const { body } = await plan({ collection_type: "daily" });
  const closedWeekdays = Object.fromEntries(
    body.cinemas.map((cinema: any) => [cinema.slug, cinema.closed_weekdays]),
  );

  assertEquals(closedWeekdays["cinema-do-centro"], ["tuesday", "wednesday"]);
  assertEquals(closedWeekdays["cine-alquimia"], []);
  assertEquals(closedWeekdays["cinemark-riomar"], []);
});

Deno.test("o plano traz os títulos na fonte resolvidos de cada cinema", async () => {
  const { body } = await plan({ collection_type: "daily" });

  for (const cinema of body.cinemas) {
    assert(Array.isArray(cinema.resolved_source_titles), cinema.slug);
    for (const resolved of cinema.resolved_source_titles) {
      assertEquals(Object.keys(resolved).sort(), ["source_title", "tmdb_id"], cinema.slug);
    }
  }
});

Deno.test("a janela é hoje e os seis dias seguintes no fuso da cidade", async () => {
  const { body } = await plan({ collection_type: "daily" }, { clock: "2026-10-01T12:00:00Z" });

  for (const cinema of body.cinemas) {
    assertEquals(cinema.timezone, "America/Maceio");
    assertEquals(cinema.window, [
      "2026-10-01",
      "2026-10-02",
      "2026-10-03",
      "2026-10-04",
      "2026-10-05",
      "2026-10-06",
      "2026-10-07",
    ]);
  }
});

Deno.test("a janela vira o dia à meia-noite no fuso da cidade, não em UTC", async () => {
  const before = await plan({ collection_type: "manual", cinemas: ["cinema-do-centro"] }, {
    clock: "2026-10-02T02:59:59Z",
  });
  const after = await plan({ collection_type: "manual", cinemas: ["cinema-do-centro"] }, {
    clock: "2026-10-02T03:00:00Z",
  });

  assertEquals(before.body.cinemas[0].window[0], "2026-10-01");
  assertEquals(before.body.cinemas[0].window[6], "2026-10-07");
  assertEquals(after.body.cinemas[0].window[0], "2026-10-02");
  assertEquals(after.body.cinemas[0].window[6], "2026-10-08");
});

Deno.test("a janela atravessa a virada do ano", async () => {
  const { body } = await plan({ collection_type: "manual", cinemas: ["cine-alquimia"] }, {
    clock: "2027-01-01T02:00:00Z",
  });

  assertEquals(body.cinemas[0].window, [
    "2026-12-31",
    "2027-01-01",
    "2027-01-02",
    "2027-01-03",
    "2027-01-04",
    "2027-01-05",
    "2027-01-06",
  ]);
});

Deno.test("o plano com cinemas escolhidos devolve só eles", async () => {
  const { status, body } = await plan({
    collection_type: "manual",
    cinemas: ["cinesercla-premio", "cinema-do-centro"],
  });

  assertEquals(status, 200);
  assertEquals(body.cinemas.map((cinema: any) => cinema.slug), [
    "cinema-do-centro",
    "cinesercla-premio",
  ]);
});

Deno.test("o plano recusa cinemas desconhecidos ou inativos, citando cada um", async () => {
  const { status, body } = await plan({
    collection_type: "manual",
    cinemas: ["cinema-do-centro", "cinema-inexistente", "cinema-desativado-de-teste"],
  });

  assertEquals(status, 400);
  assertEquals(body.error.code, "unknown_cinema");
  assertEquals(body.error.issues.map((issue: any) => issue.path), ["/cinemas/1", "/cinemas/2"]);
});

Deno.test("o plano deixa de fora os cinemas inativos", async () => {
  const { body } = await plan({ collection_type: "daily" });

  assertEquals(
    body.cinemas.some((cinema: any) => cinema.slug === "cinema-desativado-de-teste"),
    false,
  );
});

Deno.test("uma requisição fora do contrato é recusada com o caminho de cada campo errado", async () => {
  const cases: [unknown, string[]][] = [
    [{}, ["/collection_type"]],
    [{ collection_type: "weekly" }, ["/collection_type"]],
    [{ collection_type: "manual", cinemas: [] }, ["/cinemas"]],
    [{ collection_type: "manual", cinemas: ["Cinema do Centro"] }, ["/cinemas/0"]],
    [{ collection_type: "manual", cinemas: ["cine-alquimia", "cine-alquimia"] }, ["/cinemas"]],
    [{ collection_type: "daily", cinema: ["cine-alquimia"] }, ["/cinema"]],
    [{ collection_type: "daily", cinemas: ["cine-alquimia"] }, ["/cinemas"]],
    [{ collection_type: "recollection" }, ["/cinemas"]],
    [{ collection_type: "daily", site_publication: false }, ["/site_publication"]],
    [{ collection_type: "recollection", cinemas: ["cine-alquimia"], site_publication: true }, [
      "/site_publication",
    ]],
    [{ collection_type: "manual", site_publication: "no" }, ["/site_publication"]],
    [[], [""]],
  ];

  for (const [request, paths] of cases) {
    const { status, body } = await plan(request);
    assertEquals(status, 400, JSON.stringify(request));
    assertEquals(body.error.code, "invalid_request");
    assertEquals(body.error.issues.map((issue: any) => issue.path), paths, JSON.stringify(request));
  }
});

Deno.test("a ingestão recusa um corpo que não é JSON", async () => {
  const response = await fetch(`${apiUrl}/functions/v1/ingestion/collection-plan`, {
    method: "POST",
    headers: { authorization: `Bearer ${hermesToken}` },
    body: "collection_type=daily",
  });

  assertEquals(response.status, 400);
  assertEquals((await response.json()).error.code, "invalid_json");
});

Deno.test("a ingestão recusa uma chamada sem o token do Hermes ou com outro token", async () => {
  for (const token of [null, "", "token-errado", publishableKey, secretKey]) {
    const { status, body } = await plan({ collection_type: "daily" }, { token });
    assertEquals(status, 401, String(token));
    assertEquals(body.error.code, "unauthorized");
  }
});

Deno.test("a ingestão recusa uma operação desconhecida e um método diferente de POST", async () => {
  const unknown = await callIngestion("operacao-inexistente", {});
  assertEquals(unknown.status, 404);

  const get = await plan(undefined, { method: "GET" });
  assertEquals(get.status, 405);
});
