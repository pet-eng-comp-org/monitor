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
