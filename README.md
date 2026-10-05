# bubbacore/jenny

O núcleo de dados do Bubba no Supabase: o banco, a ingestão e os contratos entre as partes do projeto.

Este repositório é dono do schema e do contrato da leitura, que a coleta e o site seguem.

## O que faz

- **Banco:** é a fonte única de cidades, cinemas, fontes, filmes, pessoas e programação.
- **Ingestão:** uma Edge Function recebe as leituras do Hermes, valida o contrato e decide o que cada leitura significa. Ali ficam as regras do domínio: a janela de hoje e dos seis dias seguintes, a política de falhas, a identificação dos filmes, as recoletas, os alertas e a confiabilidade da fonte.
- **Imagens:** guarda no Supabase Storage os pôsteres e as fotos enviados pelo Hermes.
- **Acesso fechado:** o banco não tem leitura pública. O Hermes escreve só pela ingestão, com um token próprio, e o build do site lê com uma chave própria.

## Onde se encaixa

```
canais oficiais dos cinemas
  → Hermes Agent (bubbacore/forrest)
  → ingestão e banco no Supabase (bubbacore/jenny)
  → site estático (bubbacore/site)
```

A coleta só lê e identifica, e o site só mostra. As decisões sobre o que uma leitura significa ficam num só lugar, aqui, e são testadas por um só ponto, a ingestão.

## Princípios

- Uma leitura com falha apaga a programação do cinema, e o site mostra que ela está sendo atualizada. Uma programação antiga nunca aparece como atual.
- Cidades, cinemas e fontes são cadastros no banco. Uma cidade nova entra por dados, sem mudar código.
- O preço guardado é o de bilheteria, sem taxa de conveniência.

## Estado

O banco tem os cadastros da v1. O plano da coleta inicia a coleta, o início da leitura reserva o cinema dentro dela, e o registro da leitura a grava. Uma leitura com sucesso substitui toda a programação do cinema, e uma leitura com falha a apaga. O registro devolve os alertas de falha, de volta, de queda brusca de sessões, de identificação pendente e de sessão em dia sem funcionamento, e a ingestão diz quais cinemas recoletar. Um título na fonte cujo filme proposto difere do primeiro resultado da busca fica em identificação pendente, com as sessões retidas; uma leitura com todas as sessões retidas é leitura retida. A resolução liga o título na fonte ao filme escolhido naquele cinema, e o plano da coleta devolve os títulos resolvidos. Um ingresso na fonte sem tipo de ingresso informado pela fonte nem atribuído pelo dono fica em tipo de ingresso pendente, com o valor guardado fora das visões e a sessão indicando que há outros ingressos; a primeira aparição gera o alerta. A resolução atribui o tipo de ingresso, ou indica que o ingresso na fonte não é preço de bilheteria, para todos os cinemas do mesmo tipo de fonte, aplica-se aos valores guardados sem recoleta e passa a valer acima do tipo informado pela fonte, que gera um alerta quando diverge da atribuição. O fim da coleta decide se ela termina com uma publicação do site, a reversão da publicação do site suspende a publicação automática, e a ingestão devolve os resumos de coleta e diz ao vigia da coleta se a coleta diária de hoje terminou. Cada filme aceito entra no acervo com os metadados do TMDB, os gêneros, as pessoas, os créditos, o pôster, as fotos e o trailer escolhido; um filme conhecido ganha só os campos que lhe faltam, e o plano da coleta devolve, para cada filme do acervo, os campos de metadados que faltam. A classificação indicativa, a sinopse e o trailer de cada filme vêm do TMDB e, na falta dele, da fonte principal de maior confiabilidade da fonte; o trailer escolhe primeiro a versão. A atualização da confiabilidade recalcula o ranking dos tipos de fonte pelas divergências de classificação indicativa das últimas 8 semanas, guarda o histórico dos cálculos e informa quando o ranking muda. O build já tem as visões de onde lerá a programação, os filmes com o acervo e o estado de cada dia da janela. As demais operações da ingestão chegam pelos tickets da spec em vigor, a [Bubba v1](https://github.com/bubbacore/dan/blob/main/docs/specs/bubba-v1.md), publicada no Linear como [JAM-5](https://linear.app/jamesclebio/issue/JAM-5).

## Estrutura

- `supabase/migrations/`: o schema e os cadastros. Cada cadastro novo ou alterado entra numa migration de dados nova.
- `supabase/functions/ingestion/`: a ingestão, chamada em `POST /functions/v1/ingestion/<operação>`, com o token no cabeçalho `Authorization: Bearer`:
  - o Hermes chama `collection-plan`, `start-reading`, `record-image`, `record-reading`, `recollection-cinemas`, `resolve-pending-identification`, `resolve-pending-ticket-type`, `finish-collection`, `collection-summary`, `record-site-reversion`, `record-site-publication` e `update-source-reliability`;
  - o vigia da coleta chama só `daily-collection-status`, com o token próprio dele, e o token do Hermes é recusado ali.
- `contracts/reading.schema.json`: o contrato da leitura publicado em JSON Schema, para que as ferramentas de leitura do Hermes validem contra a mesma definição da ingestão. Ele é gerado pela definição em `supabase/functions/ingestion/reading-contract.ts` com `deno task contract`, e um teste falha quando o arquivo fica desatualizado. As ferramentas usam o contrato do release mais recente da Jenny.
- Imagens: o Hermes envia cada pôster e cada foto pela `record-image` antes da leitura que os cita, e a leitura cita cada imagem pelo caminho dela no TMDB. Elas ficam no bucket `images` do Storage, sem leitura pública, com o mesmo nome do caminho no TMDB. Cada imagem vai numa chamada própria, porque a Edge Function tem só 2 segundos de CPU por requisição.
- Visões do build: `site_showtimes`, com a programação, os preços de bilheteria e `other_tickets`, que indica um valor em tipo de ingresso pendente, `site_cinemas` e `site_movies`, com o acervo de cada filme em exibição, lidas só com a chave secreta do build. Os caminhos de pôster e de foto nas visões são caminhos no bucket `images`. O estado de cada dia da janela vem da função `site_cinema_days`, que recebe o momento para o qual o site é gerado.
- `supabase/seed.sql`: só os dados fixos dos testes, aplicados no banco local.
- `supabase/tests/database/`: os testes do banco, em pgTAP.
- `tests/ingestion/`: os testes da ingestão, que a chamam como o Hermes chamaria.

## Desenvolvimento local

Requer a [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started), o Deno 2 e um runtime de containers, como o Docker ou o Colima.

```sh
supabase start
supabase test db
supabase functions serve --env-file supabase/functions/test.env
deno task test
```

- O `test.env` guarda só os tokens fixos dos testes e libera o cabeçalho `x-ingestion-clock`, que fixa o relógio da ingestão. Em produção, nada disso existe.
- A CI roda os mesmos passos em todo PR e em todo push na `main`, além do `deno fmt --check`, do `deno lint` e do `deno task check`.

## Documentação

A spec, as decisões de arquitetura e o glossário do domínio ficam no [bubbacore/dan](https://github.com/bubbacore/dan). Use os termos do glossário em código, testes, issues e commits.

## Releases

A Jenny tem versão semântica própria, e o banco e a ingestão recebem somente o release aprovado mais recente, nunca a branch `main`.

- O workflow `Release Please` abre e atualiza a release PR a partir dos commits na `main`. A release PR também precisa passar nos testes: aprove os workflows que aguardam aprovação na própria PR.
- Quando o merge da release PR cria um release, o job `Database release` parte da tag do release, aplica as migrations e só depois faz o deploy da ingestão. Se as migrations falham, a ingestão não sobe.
- O job usa o segredo `SUPABASE_ACCESS_TOKEN` e a variável `SUPABASE_PROJECT_ID` do environment `production`, liberado só para a `main`. Ele não liga o projeto pela CLI, e as migrations rodam com o papel de login temporário que a CLI cria a partir do token, sem a senha do banco.
- O job não roda os testes de novo, porque eles já são verificação obrigatória da `main`.
- Se o job falhar, corrija a causa e use **Re-run failed jobs** na mesma execução. O job aplica só as migrations que faltam e sobe a ingestão de novo. Um erro no código é corrigido por um release novo.

O fluxo compartilhado está no [runbook de releases do Bubba](https://github.com/bubbacore/dan/blob/main/docs/runbooks/releases.md) e segue a [ADR 0009](https://github.com/bubbacore/dan/blob/main/docs/adr/0009-versao-semantica-por-repositorio.md).

## Como contribuir

- **Spec primeiro:** implemente só tickets de uma spec ou de um agent brief aprovado.
- **Commits:** siga o [Conventional Commits](https://www.conventionalcommits.org/pt-br/v1.0.0/), com a mensagem em inglês e no imperativo. Mantenha o assunto abaixo de 72 caracteres, faça uma mudança lógica por commit e cite o ticket no rodapé, como `Refs JAM-12`.
- **Segredos:** chaves e tokens nunca entram no repositório. O token do Hermes fica no segredo `INGESTION_HERMES_TOKEN` da ingestão, e o do vigia da coleta, no `INGESTION_WATCHMAN_TOKEN`, os dois definidos pelo dono no Supabase.
