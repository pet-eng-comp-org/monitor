# monitor

Avisa pelo [ntfy](https://ntfy.sh) quando algo da VM ou dos sites hospedados nela
sai do ar ou volta. Duas partes:

- **De fora** — workflow do GitHub Actions, a cada 5 minutos, com as checagens de
  `checks.tsv`.
- **De dentro da VM** — `vm/monitor-vm.sh`, no cron do root a cada 5 minutos:
  Portainer, disco acima de 85%, container parado, `unhealthy` ou reiniciando em
  loop, e deploy que não chegou (ver abaixo). A VM inteira fora do ar é
  detectada pela parte de fora.

## Quem recebe

| Tópico (secret) | Grupo | Para |
|---|---|---|
| `NTFY_TOPIC_VM` | `vm` e o script da VM | Manutenção |
| `NTFY_TOPIC_SITES` | `sites` | Dev |

Quem conhece o nome de um tópico lê e publica nele: tratar como senha. Para
receber, instalar o app do ntfy e assinar o tópico.

Se o grupo `vm` falha, os sites caem junto por causa dele: só o tópico da VM é
avisado, e a mensagem diz se `inf.ufes.br` (mesma faixa de IP) também caiu.

## Checagens

`checks.tsv`, uma por linha: grupo, nome, URL, condição e header opcional. A
condição é uma expressão `jq` sobre a resposta; vazia exige HTTP 200 com HTML;
`responde` aceita qualquer resposta HTTP. Rotas de API devem consultar o banco:
o site pode responder 200 e vir vazio. `pet.inf.ufes.br` responde 200 para
qualquer caminho.

Cada checagem tenta 3 vezes antes de contar como falha. Aviso só na mudança de
estado, com lembrete a cada 6 h enquanto algo segue fora. Falha nova no grupo
`vm` termina a rodada com erro, e o GitHub manda e-mail.

## Script da VM

Instalado em `/opt/monitor/monitor-vm.sh` (700, root), tópico em
`/opt/monitor/.ntfy-topic` (600, root), estado em `/opt/monitor/estado/`. Sem o
arquivo do tópico, só registra no journal: `journalctl -t monitor-vm`.

### Deploy que não chegou

Para cada stack git-ops do Portainer, confere os dois elos que falham calados:

- **busca** — o commit que o Portainer aplicou é o HEAD do ramo no GitHub? Deixa
  de ser quando o token do Portainer vence ou o repositório muda de nome/dono.
- **aplica** — as imagens dos containers da stack são as linhas `image:` do
  compose que ele buscou?

Diferença logo depois de um push é normal (o Portainer consulta a cada 5 min):
só avisa se a mesma diferença dura 15 min. Também avisa 30 dias antes de um token
do GitHub vencer.

Lê a API do Portainer com o token do backup (`/opt/backups/.portainer-token`) e
o GitHub com `/opt/monitor/.gh-token-<dono>` (600, root): o mesmo token, só
leitura, que o Portainer usa para aquele dono, para que o vencimento dele apareça
aqui. Sem o arquivo de um dono, só o elo *aplica* das stacks dele é conferido.
