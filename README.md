# bubba-jenny

O núcleo de dados do Bubba no Supabase: o banco, a ingestão e os contratos entre as partes do projeto.

O Bubba é um site público e gratuito com a programação dos cinemas de Aracaju e região metropolitana. Este repositório é dono do schema e do contrato da leitura, que a coleta e o site seguem.

## O que faz

- **Banco:** é a fonte única de cidades, cinemas, fontes, filmes, pessoas e programação.
- **Ingestão:** uma Edge Function recebe as leituras do Hermes, valida o contrato e decide o que cada leitura significa. Ali ficam as regras do domínio: a janela de hoje e dos seis dias seguintes, a política de falhas, a identificação dos filmes, as recoletas, os alertas e a confiabilidade da fonte.
- **Imagens:** guarda no Supabase Storage os pôsteres e as fotos enviados pelo Hermes.
- **Acesso fechado:** o banco não tem leitura pública. O Hermes escreve só pela ingestão, com um token próprio, e o build do site lê com uma chave própria.

## Onde se encaixa

```
canais oficiais dos cinemas
  → Hermes Agent (bubba-forrest)
  → ingestão e banco no Supabase (bubba-jenny)
  → site estático (bubba-site)
```

A coleta só lê e identifica, e o site só mostra. As decisões sobre o que uma leitura significa ficam num só lugar, aqui, e são testadas por um só ponto, a ingestão.

## Princípios

- Uma leitura com falha apaga a programação do cinema, e o site mostra que ela está sendo atualizada. Uma programação antiga nunca aparece como atual.
- Cidades, cinemas e fontes são cadastros no banco. Uma cidade nova entra por dados, sem mudar código.
- O preço guardado é o de bilheteria, sem taxa de conveniência.

## Estado

O projeto está na fase de especificação e ainda não tem código. A spec em vigor é a [Bubba v1](https://github.com/jamesclebio/bubba-dan/blob/main/docs/specs/bubba-v1.md), publicada no Linear como [JAM-5](https://linear.app/jamesclebio/issue/JAM-5). Os tickets derivados dela são suas sub-issues.

## Documentação

A spec, as decisões de arquitetura e o glossário do domínio ficam no [bubba-dan](https://github.com/jamesclebio/bubba-dan). Use os termos do glossário em código, testes, issues e commits.

## Como contribuir

- **Spec primeiro:** implemente só tickets de uma spec ou de um agent brief aprovado.
- **Commits:** siga o [Conventional Commits](https://www.conventionalcommits.org/pt-br/v1.0.0/), com a mensagem em inglês e no imperativo. Mantenha o assunto abaixo de 72 caracteres, faça uma mudança lógica por commit e cite o ticket no rodapé, como `Refs JAM-12`.
- **Segredos:** chaves e tokens nunca entram no repositório.
