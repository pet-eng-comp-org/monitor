#!/usr/bin/env bash
# Checagens de dentro da VM, a cada 5 min pelo cron do root. Avisa no ntfy (topico
# em /opt/monitor/.ntfy-topic) so quando o estado muda, com lembrete a cada 6 h.
# A VM inteira fora do ar e coberta de fora, pelo workflow do repositorio.
set -uo pipefail

DIR=/opt/monitor
ESTADO=$DIR/estado; mkdir -p "$ESTADO"; touch "$ESTADO/falhando.txt" "$ESTADO/aviso" "$ESTADO/restarts.txt"
TOPICO=$(cat "$DIR/.ntfy-topic" 2>/dev/null)
DISCO_LIMITE=${DISCO_LIMITE:-85}
LOOP_LIMITE=3          # reinicios de um mesmo container entre duas rodadas
LEMBRETE_S=$((6 * 3600))

problemas=()   # "chave<TAB>descricao"; a chave identifica o problema entre rodadas

# Portainer: a VM nao alcanca o 9443 pelo host (DOCKER-USER so aceita a VPN), entao
# a chamada sai de um container na rede do proprio Portainer, como no backup.
if ! docker run --rm --network container:portainer curlimages/curl:latest \
     -skf -m 15 -o /dev/null https://localhost:9443/api/status 2>/dev/null; then
  problemas+=("portainer"$'\t'"Portainer nao responde em /api/status")
  portainer_fora=1
fi

for mp in / /var/lib/docker; do
  uso=$(df --output=pcent "$mp" | tail -1 | tr -dc 0-9)
  [ "$uso" -ge "$DISCO_LIMITE" ] && problemas+=("disco:$mp"$'\t'"Disco $mp em ${uso}%")
done

# Containers parados, reiniciando ou unhealthy. Stack parada de proposito no
# Portainer remove os containers, entao nao aparece aqui.
while IFS=$'\t' read -r nome estado saude; do
  case "$estado" in
    running) [ "$saude" = unhealthy ] && problemas+=("unhealthy:$nome"$'\t'"$nome unhealthy") ;;
    *)       problemas+=("parado:$nome"$'\t'"$nome em estado $estado") ;;
  esac
done < <(docker ps -a --format '{{.Names}}' | xargs -r docker inspect \
          --format '{{.Name}}{{"\t"}}{{.State.Status}}{{"\t"}}{{if .State.Health}}{{.State.Health.Status}}{{end}}' \
          | sed 's#^/##')

# Loop de reinicio: o RestartCount cresce mesmo quando o container aparece "running".
atuais=$(docker ps -a --format '{{.Names}}' | xargs -r docker inspect --format '{{.Name}} {{.RestartCount}}' | sed 's#^/##')
while read -r nome n; do
  antes=$(awk -v c="$nome" '$1==c{print $2}' "$ESTADO/restarts.txt")
  [ -n "$antes" ] && [ $((n - antes)) -ge "$LOOP_LIMITE" ] && \
    problemas+=("loop:$nome"$'\t'"$nome reiniciou $((n - antes))x em 5 min")
done <<< "$atuais"
echo "$atuais" > "$ESTADO/restarts.txt"

# Deploy git-ops: o que roda tem que ser o que esta no ramo do repositorio. Dois
# elos, e cada um falha calado:
#   busca  - o Portainer trouxe o ultimo commit? ConfigHash da stack == HEAD do
#            ramo no GitHub. Para de bater se o token do Portainer vence ou o
#            repositorio muda de nome ou de dono.
#   aplica - os containers rodam o compose que ele trouxe? As imagens dos
#            containers da stack == as linhas image: do compose clonado.
# O Portainer consulta o repo a cada 5 min, entao diferenca logo depois de um push
# e normal: so vira problema quando a MESMA diferenca dura ATRASO_S.
# Token do GitHub em $DIR/.gh-token-<dono> (600): o mesmo que o Portainer usa para
# aquele dono, entao vencer o dele aparece aqui. Sem o arquivo, a busca das stacks
# daquele dono nao e checada. Aviso TOKEN_AVISO_S antes do vencimento.
COMPOSE=/var/lib/docker/volumes/portainer_data/_data/compose
PORTAINER_TOKEN=${PORTAINER_TOKEN:-/opt/backups/.portainer-token}
ATRASO_S=$((15 * 60))
TOKEN_AVISO_S=$((30 * 86400))
touch "$ESTADO/deploy-desde.txt"
SEG=$(mktemp -d); trap 'rm -rf "$SEG"' EXIT

# atrasado <chave> <marca>: verdadeiro se <chave> esta com a mesma <marca> (commit
# esperado) ha ATRASO_S ou mais. Commit novo zera o relogio.
atrasado() {
  local t
  t=$(awk -v c="$1" -v m="$2" '$1==c && $2==m {print $3}' "$ESTADO/deploy-desde.txt")
  t=${t:-$(date +%s)}
  echo "$1 $2 $t" >> "$SEG/desde"
  [ $(( $(date +%s) - t )) -ge "$ATRASO_S" ]
}

# Tokens vao ao curl por arquivo (-H @), nao pela linha de comando, que aparece no ps.
# A resposta de /api/stacks traz o Env das stacks em claro: nao sai do jq.
printf 'X-API-Key: %s\n' "$(cat "$PORTAINER_TOKEN" 2>/dev/null)" > "$SEG/portainer"
if [ -n "${portainer_fora:-}" ]; then
  :  # ja avisado acima; sem a API nao ha o que comparar
elif docker run --rm --user root --network container:portainer -v "$SEG:/seg" curlimages/curl:latest \
     -skf -m 30 -H @/seg/portainer -o /seg/stacks.json https://localhost:9443/api/stacks 2>/dev/null; then
  declare -A token_visto=()
  # Separador \x1f, nao tab: tab e espaco em branco para o read, e ReferenceName
  # vazio (ramo padrao) juntaria os campos.
  while IFS=$'\x1f' read -r id nome url ref hash arquivo; do
    repo=${url#https://github.com/}; repo=${repo%.git}; dono=${repo%%/*}
    tok="$DIR/.gh-token-$dono"
    if [ -r "$tok" ]; then
      printf 'Authorization: Bearer %s\n' "$(cat "$tok")" > "$SEG/gh"
      ramo=${ref#refs/heads/}; ramo=${ramo:-HEAD}
      code=$(curl -s -m 20 -o "$SEG/sha" -D "$SEG/cab" -w '%{http_code}' -H @"$SEG/gh" \
               -H 'Accept: application/vnd.github.sha' "https://api.github.com/repos/$repo/commits/$ramo")
      if [ "$code" = 200 ]; then
        remoto=$(cat "$SEG/sha")
        [ "$remoto" != "$hash" ] && atrasado "busca:$nome" "$remoto" && \
          problemas+=("deploy-busca:$nome"$'\t'"$nome: Portainer parado em ${hash:0:7}, $ramo ja esta em ${remoto:0:7}")
      elif atrasado "github:$nome" "$code"; then
        problemas+=("deploy-github:$nome"$'\t'"$nome: GitHub respondeu HTTP $code para $repo (token vencido ou sem acesso?)")
      fi
      vence=$(tr -d '\r' < "$SEG/cab" | sed -n 's/^github-authentication-token-expiration: //Ip')
      if [ -n "$vence" ] && [ -z "${token_visto[$dono]:-}" ]; then
        token_visto[$dono]=1
        [ $(( $(date -d "$vence" +%s) - $(date +%s) )) -lt "$TOKEN_AVISO_S" ] && \
          problemas+=("token-vence:$dono"$'\t'"Token do GitHub de $dono vence em $(date -d "$vence" +%d/%m/%Y): trocar no Portainer e em $tok")
      fi
    fi

    esperadas=$(sed -nE "s/^[[:space:]]*image:[[:space:]]*['\"]?([^'\" #]+).*/\1/p" "$COMPOSE/$id/$arquivo" 2>/dev/null | sort -u)
    rodando=$(docker ps -aq --filter "label=com.docker.compose.project=$nome" \
                | xargs -r docker inspect --format '{{.Config.Image}}' | sort -u)
    if [ "$esperadas" != "$rodando" ] && atrasado "aplica:$nome" "$hash"; then
      logger -t monitor-vm "$nome: compose espera [$(echo $esperadas)], rodando [$(echo $rodando)]"
      problemas+=("deploy-aplica:$nome"$'\t'"$nome: containers nao rodam o compose de ${hash:0:7} (detalhe: journalctl -t monitor-vm)")
    fi
  done < <(jq -r '.[] | select(.GitConfig != null and .Status == 1)
                  | [.Id, .Name, .GitConfig.URL, (.GitConfig.ReferenceName // ""), .GitConfig.ConfigHash, .EntryPoint]
                  | map(tostring) | join("\u001f")' "$SEG/stacks.json")
  sort -o "$ESTADO/deploy-desde.txt" "$SEG/desde" 2>/dev/null || : > "$ESTADO/deploy-desde.txt"
else
  problemas+=("deploy-api"$'\t'"API do Portainer recusou /api/stacks: checagem de deploy parada (token em $PORTAINER_TOKEN?)")
fi

agora=$(printf '%s\n' "${problemas[@]}" | cut -f1 | sed '/^$/d' | sort)
antes=$(sort "$ESTADO/falhando.txt")
novas=$(comm -13 <(echo "$antes") <(echo "$agora") | sed '/^$/d')
resolvidas=$(comm -23 <(echo "$antes") <(echo "$agora") | sed '/^$/d')
detalhes=$(printf '%s\n' "${problemas[@]}" | cut -f2 | sed '/^$/d')
ultimo=$(cat "$ESTADO/aviso"); ultimo=${ultimo:-0}; agora_s=$(date +%s)

avisar() { # titulo prioridade tags texto
  logger -t monitor-vm "$1 | $4"
  [ -z "$TOPICO" ] && return
  curl -s -m 20 -o /dev/null -H "Title: $1" -H "Priority: $2" -H "Tags: $3" -d "$4" "https://ntfy.sh/$TOPICO"
  echo "$agora_s" > "$ESTADO/aviso"
}

[ -n "$resolvidas" ] && avisar "VM: resolvido" default white_check_mark "$(echo $resolvidas)"
if [ -n "$novas" ]; then avisar "VM: problema novo" high rotating_light "$detalhes"
elif [ -n "$agora" ] && [ $((agora_s - ultimo)) -ge $LEMBRETE_S ]; then avisar "VM: ainda com problema" high warning "$detalhes"; fi

echo "$agora" > "$ESTADO/falhando.txt"
