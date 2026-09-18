#!/usr/bin/env bash
# Checa cada linha de checks.tsv e avisa no ntfy so quando o estado muda
# (ok -> falha, falha -> ok), com lembrete a cada 6 h enquanto algo segue fora.
# Estado anterior em $ESTADO (restaurado do cache do Actions pelo workflow).
# Sai 1 quando ha falha nova, para o GitHub mandar e-mail so nessa hora.
set -uo pipefail

ESTADO=${ESTADO:-estado/falhando.txt}
LEMBRETE_S=$((6 * 3600))
mkdir -p "$(dirname "$ESTADO")"; touch "$ESTADO" "$ESTADO.aviso"

checar() { # url condicao header -> 0 se ok; motivo em $motivo
  local url=$1 cond=$2 hdr=$3 corpo codigo
  for tentativa in 1 2 3; do
    corpo=$(mktemp)
    codigo=$(curl -s -m 20 -o "$corpo" -w '%{http_code}' ${hdr:+-H "$hdr"} "$url")
    if [ "$codigo" != 200 ]; then motivo="HTTP $codigo"
    elif [ -z "$cond" ]; then grep -qi '<html' "$corpo" && { rm -f "$corpo"; return 0; }; motivo="200 sem HTML"
    elif jq -e "$cond" "$corpo" >/dev/null 2>&1; then rm -f "$corpo"; return 0
    else motivo="200, mas sem dados: $(head -c 120 "$corpo" | tr -d '\n')"; fi
    rm -f "$corpo"; [ $tentativa -lt 3 ] && sleep 10
  done
  return 1
}

falhando=(); detalhes=""
while IFS=$'\t' read -r nome url cond hdr; do
  [[ -z "$nome" || "$nome" == \#* ]] && continue
  hdr=$(eval echo "\"$hdr\"")   # expande $INTROCOMP_API_TOKEN vindo de secret
  if checar "$url" "$cond" "$hdr"; then echo "OK     $nome"
  else echo "FALHA  $nome ($motivo)"; falhando+=("$nome"); detalhes+="$nome: $motivo"$'\n'; fi
done < checks.tsv

antes=$(sort "$ESTADO"); agora=$(printf '%s\n' "${falhando[@]}" | sed '/^$/d' | sort)
novas=$(comm -13 <(echo "$antes") <(echo "$agora") | sed '/^$/d')
voltaram=$(comm -23 <(echo "$antes") <(echo "$agora") | sed '/^$/d')
ultimo_aviso=$(cat "$ESTADO.aviso"); ultimo_aviso=${ultimo_aviso:-0}; agora_s=$(date +%s)

avisar() { # titulo prioridade tags texto
  [ -z "${NTFY_TOPIC:-}" ] && { echo "NTFY_TOPIC ausente; aviso nao enviado"; return; }
  curl -s -m 20 -o /dev/null -H "Title: $1" -H "Priority: $2" -H "Tags: $3" \
    -H "Click: ${RUN_URL:-}" -d "$4" "https://ntfy.sh/$NTFY_TOPIC"
  echo "$agora_s" > "$ESTADO.aviso"
}

[ -n "$voltaram" ] && avisar "Voltou: $(echo $voltaram)" default white_check_mark "No ar de novo: $(echo $voltaram)"
if [ -n "$novas" ]; then
  avisar "FORA: $(echo $novas)" high rotating_light "$detalhes"
elif [ -n "$agora" ] && [ $((agora_s - ultimo_aviso)) -ge $LEMBRETE_S ]; then
  avisar "Ainda fora: $(echo $agora)" high warning "$detalhes"
fi

echo "$agora" > "$ESTADO"
[ -z "$novas" ]
