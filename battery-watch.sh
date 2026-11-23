#!/data/data/com.termux/files/usr/bin/bash
# termux-battery-watch: Android -> WhatsApp via Evolution API
# Sem root e sem cron. Termux:API e preferido; sysfs e fallback.
set -uo pipefail
umask 077

MODO="${1:-run}"
case "$MODO" in
  run|--status) ;;
  *) printf 'Uso: %s [--status]\n' "$0" >&2; exit 2 ;;
esac

CONF="${BATWATCH_CONF:-$HOME/.battery-watch.conf}"
DRY_AMBIENTE="${DRY:-}"
if [[ -f "$CONF" ]]; then
  # O arquivo e executado como shell; mantenha-o privado e confiavel.
  # shellcheck disable=SC1090
  source "$CONF"
elif [[ "$MODO" == run ]]; then
  printf 'ERRO: falta %s\n' "$CONF" >&2
  exit 2
fi
DRY="${DRY_AMBIENTE:-${DRY:-0}}"
INTERVALO="${INTERVALO:-60}"
LIMIAR_BAIXO="${LIMIAR_BAIXO:-30}"
LIMIAR_RESET="${LIMIAR_RESET:-33}"
LIMIAR_CHEIO="${LIMIAR_CHEIO:-100}"
LIMIAR_CHEIO_RESET="${LIMIAR_CHEIO_RESET:-98}"
STATE="${BATWATCH_STATE:-$HOME/.battery-watch.state}"
LOG="${BATWATCH_LOG:-$HOME/.battery-watch.log}"
CURLRC="${BATWATCH_CURLRC:-$HOME/.battery-watch.curlrc}"
LOCK="${BATWATCH_LOCK:-$HOME/.battery-watch.lock}"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
erro() { printf 'ERRO: %s\n' "$*" >&2; exit 2; }

# Retorna: percentual STATUS PLUGGED (sem espacos internos).
# Exemplo: 42 CHARGING PLUGGED_AC
bateria() {
  local j dados d tipo cap status plug p fonte online
  if command -v termux-battery-status >/dev/null 2>&1 && \
     command -v timeout >/dev/null 2>&1 && \
     command -v jq >/dev/null 2>&1; then
    if j="$(timeout 5s termux-battery-status 2>/dev/null)"; then
      dados="$(printf '%s' "$j" | jq -er \
        'if (.percentage | type) == "number" then "\(.percentage | floor) \(.status // "UNKNOWN") \(.plugged // "UNKNOWN")" else empty end' \
        2>/dev/null)" || dados=""
      if [[ -n "$dados" ]]; then
        printf '%s\n' "$dados"
        return 0
      fi
    fi
  fi

  # Em alguns Androids /sys e inacessivel. Nunca escolher uma fonte
  # que nao seja do tipo Battery (ex.: USB, wireless, AC).
  for d in /sys/class/power_supply/battery /sys/class/power_supply/BAT0 /sys/class/power_supply/*; do
    [[ -r "$d/type" && -r "$d/capacity" && -r "$d/status" ]] || continue
    tipo="$(cat "$d/type" 2>/dev/null)" || continue
    [[ "${tipo,,}" == battery ]] || continue
    cap="$(cat "$d/capacity" 2>/dev/null)" || continue
    status="$(cat "$d/status" 2>/dev/null)" || continue
    status="${status^^}"
    status="${status// /_}"
    plug="UNKNOWN"
    case "$status" in
      CHARGING|FULL) plug="PLUGGED_OTHER" ;;
      DISCHARGING) plug="UNPLUGGED" ;;
    esac
    for p in /sys/class/power_supply/*/online; do
      [[ -r "$p" && -r "${p%/online}/type" ]] || continue
      fonte="$(cat "${p%/online}/type" 2>/dev/null)" || continue
      [[ "${fonte,,}" == battery ]] && continue
      online="$(cat "$p" 2>/dev/null)" || continue
      if [[ "$online" == 1 ]]; then plug="PLUGGED_OTHER"; break; fi
    done
    printf '%s %s %s\n' "$cap" "$status" "$plug"
    return 0
  done
  return 1
}

# Inspecao sem rede nem alteracao de estado, mesmo sem configuracao da Evolution.
if [[ "$MODO" == --status ]]; then
  if saida="$(bateria)"; then
    read -r CAP STATUS PLUG <<< "$saida"
    printf 'Bateria: %s%% | status: %s | fonte: %s\n' "$CAP" "$STATUS" "$PLUG"
    exit 0
  fi
  erro 'nao foi possivel ler a bateria; verifique Termux:API e pkg install termux-api jq coreutils'
fi

for nome in EVO_URL EVO_TOKEN EVO_INSTANCE DESTINO; do
  [[ -n "${!nome:-}" ]] || erro "defina $nome em $CONF"
done
for nome in INTERVALO LIMIAR_BAIXO LIMIAR_RESET LIMIAR_CHEIO LIMIAR_CHEIO_RESET; do
  [[ "${!nome}" =~ ^[0-9]+$ ]] || erro "$nome deve ser numerico"
done
(( 10#$INTERVALO >= 1 )) || erro 'INTERVALO deve ser maior que zero'
(( 10#$LIMIAR_BAIXO <= 100 && 10#$LIMIAR_RESET <= 100 && 10#$LIMIAR_CHEIO <= 100 && 10#$LIMIAR_CHEIO_RESET <= 100 )) || erro 'limiares devem estar entre 0 e 100'
(( 10#$LIMIAR_RESET > 10#$LIMIAR_BAIXO )) || erro 'LIMIAR_RESET precisa superar LIMIAR_BAIXO'
(( 10#$LIMIAR_CHEIO_RESET < 10#$LIMIAR_CHEIO )) || erro 'LIMIAR_CHEIO_RESET precisa ser menor que LIMIAR_CHEIO'
[[ "$DRY" == 0 || "$DRY" == 1 ]] || erro 'DRY deve ser 0 ou 1'
[[ "$DESTINO" =~ ^[0-9]{10,15}$ ]] || erro 'DESTINO deve ter entre 10 e 15 digitos, sem +'
# Valida a URL completa antes de preparar qualquer credencial.
# HTTP e permitido somente em testes locais, quando autorizado explicitamente.
validar_url() {
  local esquema autoridade host porta
  if [[ "$EVO_URL" =~ ^(https?)://([^/?#]+)(/[^?#]*)?$ ]]; then
    esquema="${BASH_REMATCH[1]}"
    autoridade="${BASH_REMATCH[2]}"
  else
    erro 'EVO_URL invalida: informe endereco com protocolo, host e sem parametros'
  fi
  [[ "$autoridade" != *'@'* ]] || erro 'EVO_URL nao pode conter credenciais'
  if [[ "$autoridade" =~ ^(\[[[:xdigit:]:]+\]|[A-Za-z0-9.-]+)(:([0-9]{1,5}))?$ ]]; then
    host="${BASH_REMATCH[1]}"
    porta="${BASH_REMATCH[3]:-}"
  else
    erro 'EVO_URL contem host ou porta invalida'
  fi
  if [[ -n "$porta" ]]; then
    (( 10#$porta >= 1 && 10#$porta <= 65535 )) || erro 'EVO_URL contem porta fora do intervalo'
  fi
  if [[ "$esquema" == http ]]; then
    [[ "${BATWATCH_ALLOW_HTTP_LOOPBACK:-0}" == 1 &&
       ( "$host" == localhost || "$host" == 127.0.0.1 || "$host" == '[::1]' ) ]] ||
      erro 'HTTP e permitido apenas em loopback com BATWATCH_ALLOW_HTTP_LOOPBACK=1'
  fi
  EVO_PROTO="$esquema"
}
validar_url
command -v jq >/dev/null 2>&1 || erro 'instale jq: pkg install jq'
command -v curl >/dev/null 2>&1 || erro 'instale curl: pkg install curl'
command -v flock >/dev/null 2>&1 || erro 'instale flock: pkg install util-linux'
command -v timeout >/dev/null 2>&1 || erro 'instale timeout: pkg install coreutils'
EVO_URL="${EVO_URL%/}"

if [[ "$DRY" == 1 ]]; then
  STATE="${STATE}.dry"  # testes nunca alteram os alertas de producao
  LOCK="${LOCK}.dry"    # testes nao bloqueiam a instancia de producao
fi
touch "$LOG" "$STATE" "$LOCK" || erro 'nao foi possivel criar arquivos locais'
chmod 600 "$LOG" "$STATE" "$LOCK" 2>/dev/null || true
[[ -f "$CONF" ]] && chmod 600 "$CONF" 2>/dev/null || true

# Impede dois monitores concorrentes (incluindo duas execucoes DRY).
exec 9>"$LOCK"
if ! flock -n 9; then
  erro 'monitor ja esta em execucao; evite processos duplicados'
fi

# Atualiza o header a cada execucao; nunca reutiliza um token antigo.
# Credenciais nao aparecem nos argumentos do curl nem no historico.
if [[ "$DRY" == 0 ]]; then
  [[ "$EVO_TOKEN" != *$'\n'* && "$EVO_TOKEN" != *$'\r'* && "$EVO_TOKEN" != *'"'* && "$EVO_TOKEN" != *'\'* ]] || erro 'EVO_TOKEN contem caracteres invalidos para o arquivo curl'
  printf 'header = "apikey: %s"\nheader = "Content-Type: application/json"\n' "$EVO_TOKEN" > "$CURLRC" || erro 'falha ao gravar credenciais do curl'
  chmod 600 "$CURLRC" 2>/dev/null || true
fi

ler() { sed -n "s/^$1=//p" "$STATE" 2>/dev/null | tail -1; }
grava() {
  local k="$1" v="$2"
  if grep -q "^$k=" "$STATE" 2>/dev/null; then
    sed -i "s|^$k=.*|$k=$v|" "$STATE"
  else
    printf '%s=%s\n' "$k" "$v" >> "$STATE"
  fi
}
envia() {
  local msg="$1" payload http rc
  if [[ "$DRY" == 1 ]]; then
    log "DRY msg=$msg"
    printf '[DRY] %s\n' "$msg"
    return 0
  fi
  payload="$(jq -cn --arg number "$DESTINO" --arg text "$msg" '{number:$number,text:$text}')" || return 1
  # -q deve ser a primeira opcao: ignora ~/.curlrc, mas preserva o -K privado.
  # Nao seguir redirecionamentos nem permitir outro protocolo de transporte.
  http="$(curl -q --proto "=$EVO_PROTO" --proto-redir "=$EVO_PROTO" \
    --max-redirs 0 -sS --connect-timeout 8 --max-time 25 -K "$CURLRC" \
    -X POST "$EVO_URL/message/sendText/$EVO_INSTANCE" \
    --data-binary "$payload" -o /dev/null -w '%{http_code}')"
  rc=$?
  if [[ "$rc" -eq 0 && "$http" =~ ^2[0-9][0-9]$ ]]; then
    log "OK http=$http msg=$msg"
    return 0
  fi
  log "ERRO curl=$rc http=${http:-sem-resposta} msg=$msg"
  return 1
}

if command -v termux-wake-lock >/dev/null 2>&1; then
  timeout 5s termux-wake-lock >/dev/null 2>&1 || log 'AVISO: nao foi possivel obter wake-lock'
fi
log "inicio pid=$$ DRY=$DRY intervalo=${INTERVALO}s destino=${DESTINO:0:4}***"
PRIMEIRA=0
[[ -s "$STATE" ]] || PRIMEIRA=1
[[ "$PRIMEIRA" == 1 ]] && grava inicializado 1

while :; do
  if ! leitura="$(bateria)"; then
    log 'leitura da bateria indisponivel; nova tentativa no proximo intervalo'
    sleep "$INTERVALO"
    continue
  fi
  read -r CAP STATUS FONTE <<< "$leitura"
  if [[ ! "$CAP" =~ ^[0-9]{1,3}$ ]] || (( 10#$CAP > 100 )); then
    log "leitura invalida cap='$CAP' status='$STATUS'"
    sleep "$INTERVALO"
    continue
  fi

  # O campo plugged prevalece sobre status, inclusive em NOT_CHARGING.
  PLUGADO='desconhecido'
  case "$FONTE" in
    PLUGGED_*) PLUGADO=1 ;;
    UNPLUGGED) PLUGADO=0 ;;
  esac
  if [[ "$PLUGADO" == desconhecido ]]; then
    case "$STATUS" in
      CHARGING|FULL) PLUGADO=1 ;;
      DISCHARGING) PLUGADO=0 ;;
    esac
  fi

  if [[ "$PRIMEIRA" == 1 ]]; then
    # Nao avisa transicoes anteriores ao inicio; bateria baixa avisa ja.
    [[ "$PLUGADO" == 1 ]] && grava plugado_avisado 1
    (( 10#$CAP >= 10#$LIMIAR_CHEIO )) && grava cheio_avisado 1
    log "baseline cap=$CAP status=$STATUS fonte=$FONTE plugado=$PLUGADO"
    PRIMEIRA=0
  fi

  if (( 10#$CAP <= 10#$LIMIAR_BAIXO )) && [[ "$PLUGADO" == 0 ]] && [[ "$(ler baixo_avisado)" != 1 ]]; then
    if envia "🔋 Bateria baixa: ${CAP}% (descarregando). Coloque para carregar."; then grava baixo_avisado 1; fi
  fi
  if (( 10#$CAP > 10#$LIMIAR_RESET )); then grava baixo_avisado 0; fi

  if [[ "$PLUGADO" == 1 ]] && (( 10#$CAP < 10#$LIMIAR_CHEIO )) && [[ "$(ler plugado_avisado)" != 1 ]]; then
    if envia "🔌 Carregador conectado — bateria em ${CAP}%."; then grava plugado_avisado 1; fi
  fi
  [[ "$PLUGADO" == 0 ]] && grava plugado_avisado 0

  if (( 10#$CAP >= 10#$LIMIAR_CHEIO )) && [[ "$(ler cheio_avisado)" != 1 ]]; then
    if envia "✅ Bateria em ${CAP}% — carga completa, pode desconectar."; then grava cheio_avisado 1; fi
  fi
  if (( 10#$CAP < 10#$LIMIAR_CHEIO_RESET )); then grava cheio_avisado 0; fi

  grava ultimo "$CAP"
  sleep "$INTERVALO"
done
