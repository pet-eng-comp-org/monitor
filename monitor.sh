#!/usr/bin/env bash
# Checa cada linha de checks.tsv e avisa no ntfy por grupo, so quando o estado
# muda (ok -> falha, falha -> ok), com lembrete a cada 6 h enquanto algo segue fora.
#
# Cada grupo avisa no topico do secret NTFY_TOPIC_<GRUPO>; grupo sem topico nao
# avisa. O grupo `vm` e a base: se ele falha, os sites caem junto por causa dele,
# entao os outros grupos nao avisam nem mudam de estado ate a VM voltar.
#
# Sai 1 quando ha falha nova num grupo de $GRUPOS_EMAIL, para o GitHub mandar
# e-mail (vai para quem editou o cron por ultimo) so nesses casos.
set -uo pipefail

ESTADO=${ESTADO:-estado}
LEMBRETE_S=$((6 * 3600))
mkdir -p "$ESTADO"
agora_s=$(date +%s)

checar() { # url condicao header -> 0 se ok; motivo em $motivo
  local url=$1 cond=$2 hdr=$3 corpo codigo
  for tentativa in 1 2 3; do
    corpo=$(mktemp)
    # No IP da VM o certificado nao casa; para "responde" basta o Traefik atender.
    codigo=$(curl -s -m 20 $([ "$cond" = responde ] && echo -k) -o "$corpo" -w '%{http_code}' ${hdr:+-H "$hdr"} "$url")
    if [ "$cond" = "responde" ]; then            # qualquer resposta HTTP serve
      [ "$codigo" != 000 ] && { rm -f "$corpo"; return 0; }; motivo="sem resposta"
    elif [ "$codigo" != 200 ]; then motivo="HTTP $codigo"
    elif [ -z "$cond" ]; then grep -qi '<html' "$corpo" && { rm -f "$corpo"; return 0; }; motivo="200 sem HTML"
    elif jq -e "$cond" "$corpo" >/dev/null 2>&1; then rm -f "$corpo"; return 0
    else motivo="200, mas sem dados: $(head -c 120 "$corpo" | tr -d '\n')"; fi
    rm -f "$corpo"; [ $tentativa -lt 3 ] && sleep 10
  done
  return 1
}

declare -A falhas detalhes
grupos=()
while IFS=$'\t' read -r grupo nome url cond hdr; do
  [[ -z "$grupo" || "$grupo" == \#* ]] && continue
  [[ " ${grupos[*]} " == *" $grupo "* ]] || grupos+=("$grupo")
  hdr=$(eval echo "\"$hdr\"")   # expande variaveis vindas de secret
  if checar "$url" "$cond" "$hdr"; then echo "OK     $grupo/$nome"
  else
    echo "FALHA  $grupo/$nome ($motivo)"
    falhas[$grupo]+="$nome"$'\n'; detalhes[$grupo]+="$nome: $motivo"$'\n'
  fi
done < checks.tsv

vm_fora=${falhas[vm]:+sim}
if [ -n "$vm_fora" ]; then
  # Distingue VM de rede do DI: inf.ufes.br esta na mesma faixa 200.137.66.x.
  if curl -s -m 15 -o /dev/null https://inf.ufes.br/; then
    detalhes[vm]+=$'\n'"inf.ufes.br responde: o problema e da VM, nao da rede do DI."
  else
    detalhes[vm]+=$'\n'"inf.ufes.br tambem fora: provavel queda da rede do DI (faixa 200.137.66.x)."
  fi
fi

avisar() { # topico arquivo_aviso titulo prioridade tags texto
  [ -z "$1" ] && return
  curl -s -m 20 -o /dev/null -H "Title: $3" -H "Priority: $4" -H "Tags: $5" \
    -H "Click: ${RUN_URL:-}" -d "$6" "https://ntfy.sh/$1"
  echo "$agora_s" > "$2"
}

email=0
for g in "${grupos[@]}"; do
  if [ "$g" != vm ] && [ -n "$vm_fora" ]; then echo "($g: silenciado, VM fora)"; continue; fi
  arq="$ESTADO/$g.txt"; touch "$arq" "$arq.aviso"
  var="NTFY_TOPIC_${g^^}"; var=${var//-/_}; topico=${!var:-}
  antes=$(sort "$arq"); agora=$(printf '%s' "${falhas[$g]:-}" | sed '/^$/d' | sort)
  novas=$(comm -13 <(echo "$antes") <(echo "$agora") | sed '/^$/d')
  voltaram=$(comm -23 <(echo "$antes") <(echo "$agora") | sed '/^$/d')
  ultimo=$(cat "$arq.aviso"); ultimo=${ultimo:-0}

  [ -n "$voltaram" ] && avisar "$topico" "$arq.aviso" "Voltou: $(echo $voltaram)" default white_check_mark "No ar de novo: $(echo $voltaram)"
  if [ -n "$novas" ]; then
    avisar "$topico" "$arq.aviso" "FORA: $(echo $novas)" high rotating_light "${detalhes[$g]}"
    [[ " ${GRUPOS_EMAIL:-} " == *" $g "* ]] && email=1
  elif [ -n "$agora" ] && [ $((agora_s - ultimo)) -ge $LEMBRETE_S ]; then
    avisar "$topico" "$arq.aviso" "Ainda fora: $(echo $agora)" high warning "${detalhes[$g]}"
  fi
  echo "$agora" > "$arq"
done

[ "$email" = 0 ]
