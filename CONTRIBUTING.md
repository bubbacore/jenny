# Como contribuir com a Jenny

Este guia reúne o que vale para qualquer mudança neste repositório, feita por uma pessoa ou por um agente. Ele descreve o padrão que o código já segue.

## Antes de começar

- **Spec primeiro:** implemente só tickets de uma spec ou de um agent brief aprovado.
- **Commits:** siga o [Conventional Commits](https://www.conventionalcommits.org/pt-br/v1.0.0/), com a mensagem em inglês e no imperativo. Mantenha o assunto abaixo de 72 caracteres, faça uma mudança lógica por commit e cite o ticket no rodapé, como `Refs JAM-12`. Marque com `!` ou `BREAKING CHANGE` o commit que quebra um contrato ou um comportamento esperado.
- **Segredos:** chaves e tokens nunca entram no repositório. O token do Hermes fica no segredo `INGESTION_HERMES_TOKEN` da ingestão, e o do vigia da coleta, no `INGESTION_WATCHMAN_TOKEN`, os dois definidos pelo dono no Supabase.
- **Idioma:** o código, os comentários e os commits ficam em inglês, e o que o dono, o público e o Hermes leem fica em português, conforme a [ADR 0011](https://github.com/bubbacore/dan/blob/main/docs/adr/0011-codigo-em-ingles-e-textos-em-portugues.md) do `bubbacore/dan`. Os termos do glossário usam o nome em inglês fixado no `CONTEXT.md`.

## Ambiente e verificações locais

Requer a [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started), o Deno 2 e um runtime de containers, como o Docker ou o Colima.

Rode tudo o que o workflow `Tests` roda, na mesma ordem:

```sh
deno fmt --check
deno lint
deno task check
supabase start
supabase db lint --local --schema public,private --level warning --fail-on warning
supabase test db
supabase functions serve --env-file supabase/functions/test.env
deno task test
```

- O `deno fmt` usa linha de 100 colunas e cobre `supabase/functions/`, `scripts/` e `tests/`. Rode `deno fmt` sem `--check` para formatar.
- O `supabase db lint` roda o plpgsql_check nas funções dos schemas `public` e `private`. Qualquer aviso falha a CI.
- O `supabase functions serve` fica em primeiro plano; rode o `deno task test` noutro terminal.
- Depois de mudar o contrato da leitura em `supabase/functions/ingestion/reading-contract.ts`, rode `deno task contract` para regerar `contracts/reading.schema.json`. Um teste falha quando o arquivo fica desatualizado.
- Depois de criar uma migration, rode `supabase db reset` para aplicar todas do zero com o `seed.sql`.

## TypeScript da ingestão

O `deno fmt` e o `deno lint` cuidam da forma. Além deles:

- **Uma operação por módulo:** cada operação da ingestão fica num arquivo com o nome dela em `supabase/functions/ingestion/`, como `start-reading.ts`, e exporta uma função `(body: unknown, context: Context) => Promise<Response>`. O `handler.ts` liga o nome da operação à função e diz quem pode chamá-la, o Hermes ou o vigia da coleta.
- **Validação pelo Zod:** cada módulo declara o esquema da requisição com `z.strictObject`, que recusa campos desconhecidos, valida o corpo com `safeParse` e, na falha, responde com `invalidRequest`, de `http.ts`, que devolve uma questão por campo errado com o caminho em JSON Pointer.
- **Recusas com `code` tipado:** o resultado da função do banco é um tipo união com o sucesso e `{ refusal: { code: ... } }`, cada `code` como literal em `snake_case`. A ingestão traduz cada recusa com `failure(status, code, message)`.
- **Mensagens ao dono em português:** as mensagens de erro, as descrições dos campos do contrato (`.describe(...)`) e os alertas ficam em português, com os termos do glossário. Os logs (`console.error`) e os comentários ficam em inglês.
- **Divisão das regras:** o TypeScript valida a forma da requisição, aplica as regras que não precisam do banco e traduz o resultado em resposta HTTP. As regras que leem ou gravam dados, como a janela, a política de falhas, as recoletas e os alertas, ficam nas funções do banco, chamadas por `database.rpc(...)`, em geral uma só por requisição, para que a operação inteira rode numa transação. Um `error` do `rpc` é lançado e vira `internal_error`.
- **Comentários:** cada função exportada tem um comentário acima dela que explica o porquê.

## SQL e migrations

### Estilo

- Palavras-chave em minúsculas, indentação de dois espaços e nomes sempre qualificados pelo schema, como `public.readings`.
- Toda função define `set search_path = ''`.
- Toda tabela tem RLS ligada e nenhum acesso de `anon` e `authenticated`. Cada função pública revoga a execução de `anon`, `authenticated` e `public` e concede a `service_role`.
- As funções que a ingestão chama ficam no schema `public`, e as funções auxiliares, no schema `private`.
- Um comentário acima de cada tabela, função, visão ou constraint explica o porquê.
- As funções em plpgsql passam no plpgsql_check: inicializações com conversão explícita, como `'[]'::jsonb`, e nenhuma variável não usada ou encoberta.

### Nomes

- Índices simples: `<tabela>_<colunas>_idx`, como `readings_cinema_id_started_at_idx`.
- Índices únicos parciais e constraints: o nome da tabela seguido da regra, como `readings_one_in_progress_per_cinema` e `readings_success_is_complete`.

### Migrations

- O arquivo se chama `<timestamp>_<verbo>_<objeto>.sql`, com o verbo no imperativo em inglês, como `20261003120100_record_failed_readings.sql`.
- Uma migration aplicada nunca muda, porque ela é registro. Toda correção entra numa migration nova.
- Uma função redefinida vem inteira numa migration nova, a partir da definição mais recente, com `create or replace function`, e com o comentário já escrito com os nomes em inglês dos termos do glossário.
- Cada cadastro novo ou alterado entra numa migration de dados nova.

## Testes

- **Banco:** pgTAP em `supabase/tests/database/`, rodado por `supabase test db`.
- **Ingestão:** Deno em `tests/ingestion/`, que chama a ingestão como o Hermes chamaria, com o relógio fixado pelo cabeçalho `x-ingestion-clock`. O contrato publicado tem o teste em `tests/contract/`.
- Os nomes dos testes e das seções ficam em português, com os termos do glossário, para que o dono os confira contra a spec.
- `supabase/seed.sql` guarda só os dados fixos dos testes.
