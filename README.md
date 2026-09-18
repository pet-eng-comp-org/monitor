# monitor

Checa a cada 5 minutos os sites hospedados na VM e avisa no celular pelo
[ntfy](https://ntfy.sh) quando algum sai do ar ou volta.

Para receber os avisos: instalar o app do ntfy e assinar o tópico configurado
no secret `NTFY_TOPIC`. Quem conhece o nome do tópico lê e publica nele: tratar
como senha.

## Checagens

Ficam em `checks.tsv`, uma por linha: nome, URL, condição `jq` sobre a resposta
e header opcional. Sem condição, basta HTTP 200 com HTML. Rotas de API devem
consultar o banco: o site pode responder 200 e vir vazio.

Cada checagem tenta 3 vezes antes de contar como falha. Aviso só na mudança de
estado, com lembrete a cada 6 h enquanto algo segue fora. A rodada que detecta
falha nova termina com erro, e o GitHub manda e-mail.

## Secrets

- `NTFY_TOPIC` — tópico do ntfy.
- `INTROCOMP_API_TOKEN` — valor do header `authorization` que o front do
  IntroComp envia à API.

Rodar à mão: aba Actions → monitor → Run workflow.
