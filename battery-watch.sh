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
# Modelos opcionais: o marcador {percentual} é literal no arquivo de configuração.
[[ -n "${MSG_BAIXA_DESCONECTADO:-}" ]] || MSG_BAIXA_DESCONECTADO='🔋 Bateria baixa: {percentual}% (descarregando). Coloque para carregar.'
[[ -n "${MSG_BAIXA_CONECTADO:-}" ]] || MSG_BAIXA_CONECTADO='🔋 Bateria baixa: {percentual}% apesar da fonte conectada. Verifique o carregamento.'
[[ -n "${MSG_BAIXA_DESCONHECIDO:-}" ]] || MSG_BAIXA_DESCONHECIDO='🔋 Bateria baixa: {percentual}%. Nao foi possivel confirmar a alimentacao.'
[[ -n "${MSG_CARREGADOR_CONECTADO:-}" ]] || MSG_CARREGADOR_CONECTADO='🔌 Carregador conectado — bateria em {percentual}%.'
[[ -n "${MSG_CARGA_COMPLETA:-}" ]] || MSG_CARGA_COMPLETA='✅ Bateria em {percentual}% — carga completa, pode desconectar.'
[[ -n "${MSG_CARREGADOR_INFERIDO:-}" ]] || MSG_CARREGADOR_INFERIDO='🔌 Carregamento detectado — bateria em {percentual}% (fonte inferida).'

renderizar_mensagem() {
  local modelo="$1" percentual="$2"
  # Atribuição direta preserva inclusive quebras de linha finais; sem eval.
  aviso="${modelo//\{percentual\}/$percentual}"
}
STATE="${BATWATCH_STATE:-$HOME/.battery-watch.state}"
LOG="${BATWATCH_LOG:-$HOME/.battery-watch.log}"
CURLRC="${BATWATCH_CURLRC:-$HOME/.battery-watch.curlrc}"
LOCK="${BATWATCH_LOCK:-$HOME/.battery-watch.lock}"
LOG_MAX_BYTES="${BATWATCH_LOG_MAX_BYTES:-1048576}"
ULTIMO_LOG=''
LOG_REPETICOES=0

escrever_log() {
  local tamanho=0
  [[ -f "$LOG" ]] && tamanho="$(wc -c < "$LOG" 2>/dev/null || printf 0)"
  if (( tamanho >= 10#$LOG_MAX_BYTES )); then
    # O monitor abre o arquivo a cada escrita; dois historicos bastam.
    [[ ! -f "${LOG}.1" ]] || mv -f "${LOG}.1" "${LOG}.2"
    mv -f "$LOG" "${LOG}.1" || return 1
  fi
  printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"
}

log() {
  local msg="$*" repetivel=0
  # Só falhas repetitivas de leitura podem ser agrupadas; cada envio tem sua linha.
  case "$msg" in
    'leitura da bateria indisponivel;'*|'leitura invalida '*) repetivel=1 ;;
  esac
  # Mensagem configurável pode ser multilinha; não forjar registros no log.
  msg="${msg//$'\r'/\\r}"
  msg="${msg//$'\n'/\\n}"
  if [[ "$repetivel" == 1 && "$msg" == "$ULTIMO_LOG" ]]; then
    LOG_REPETICOES=$(( LOG_REPETICOES + 1 ))
    # Registra periodicamente a repeticao, sem poluir a cada ciclo.
    if (( LOG_REPETICOES % 60 == 0 )); then
      escrever_log "REPETIDO ${LOG_REPETICOES} vezes: $msg"
    fi
    return 0
  fi
  if (( LOG_REPETICOES > 0 )); then
    escrever_log "RESUMO: $ULTIMO_LOG repetido $LOG_REPETICOES vezes adicionais"
  fi
  ULTIMO_LOG=''
  [[ "$repetivel" == 0 ]] || ULTIMO_LOG="$msg"
  LOG_REPETICOES=0
  escrever_log "$msg"
}
erro() { printf 'ERRO: %s\n' "$*" >&2; exit 2; }

# Retorna: percentual STATUS PLUGGED (sem espacos internos).
# Exemplo: 42 CHARGING PLUGGED_AC
bateria() {
  local j dados d tipo cap status plug p fonte online origem
  local lidas=0 incompletas=0 raiz="${BATWATCH_SYSFS_ROOT:-/sys/class/power_supply}"
  if command -v termux-battery-status >/dev/null 2>&1 && \
     command -v timeout >/dev/null 2>&1 && \
     command -v jq >/dev/null 2>&1; then
    if j="$(timeout 5s termux-battery-status 2>/dev/null)"; then
      dados="$(printf '%s' "$j" | jq -er \
        'if (.percentage | type) == "number" then "\(.percentage | floor) \(.status // "UNKNOWN") \(.plugged // "UNKNOWN")" else empty end' \
        2>/dev/null)" || dados=""
      if [[ -n "$dados" ]]; then
        # A origem API permite diferenciar dados confirmados de inferencias do kernel.
        printf '%s API\n' "$dados"
        return 0
      fi
    fi
  fi

  # Em alguns Androids /sys e inacessivel. Nunca escolher uma fonte
  # que nao seja do tipo Battery (ex.: USB, wireless, AC).
  for d in "$raiz"/battery "$raiz"/BAT0 "$raiz"/*; do
    [[ -r "$d/type" && -r "$d/capacity" && -r "$d/status" ]] || continue
    tipo="$(cat "$d/type" 2>/dev/null)" || continue
    [[ "${tipo,,}" == battery ]] || continue
    cap="$(cat "$d/capacity" 2>/dev/null)" || continue
    status="$(cat "$d/status" 2>/dev/null)" || continue
    status="${status^^}"
    status="${status// /_}"
    # Diferencia evidência explícita de alimentação e inferência pelo estado.
    plug="UNKNOWN"
    origem="SYSFS_INFERIDO"
    for p in "$raiz"/*/online; do
      [[ -e "$p" ]] || continue
      if ! fonte="$(cat "${p%/online}/type" 2>/dev/null)"; then
        incompletas=1; continue
      fi
      [[ "${fonte,,}" == battery ]] && continue
      if ! online="$(cat "$p" 2>/dev/null)"; then
        incompletas=1; continue
      fi
      case "$online" in
        1) plug="PLUGGED_OTHER"; origem="SYSFS_ONLINE"; break ;;
        0) lidas=$((lidas + 1)) ;;
        *) incompletas=1 ;;
      esac
    done
    if [[ "$origem" != SYSFS_ONLINE ]]; then
      if (( lidas > 0 && incompletas == 0 )) && [[ "$status" != CHARGING ]]; then
        plug="UNPLUGGED"; origem="SYSFS_OFFLINE"
      else
        # Sem confirmação pelo kernel, só CHARGING/DISCHARGING sugerem transição.
        # FULL e NOT_CHARGING não provam conexão nem desconexão física.
        case "$status" in
          CHARGING) plug="PLUGGED_OTHER" ;;
          DISCHARGING) plug="UNPLUGGED" ;;
        esac
      fi
    fi
    printf '%s %s %s %s\n' "$cap" "$status" "$plug" "$origem"
    return 0
  done
  return 1
}

# Inspecao sem rede nem alteracao de estado, mesmo sem configuracao da Evolution.
if [[ "$MODO" == --status ]]; then
  if saida="$(bateria)"; then
    read -r CAP STATUS PLUG ORIGEM <<< "$saida"
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
[[ "$LOG_MAX_BYTES" =~ ^[0-9]{1,9}$ ]] &&
  (( 10#$LOG_MAX_BYTES >= 1024 && 10#$LOG_MAX_BYTES <= 104857600 )) ||
  erro 'BATWATCH_LOG_MAX_BYTES deve estar entre 1024 e 104857600'
# A Evolution usa o campo number tanto para contatos quanto para grupos.
if [[ ! "$DESTINO" =~ ^[0-9]{10,15}$ && ! "$DESTINO" =~ ^[0-9]+(-[0-9]+)?@g[.]us$ ]]; then
  erro 'DESTINO invalido: use numero internacional sem + ou identificador de grupo @g.us'
fi
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

# O nome e um segmento da rota; caracteres especiais devem ser codificados.
# Nao impor uma lista ASCII: a API pode aceitar nomes com espacos ou Unicode.
(( ${#EVO_INSTANCE} <= 255 )) || erro 'EVO_INSTANCE excede 255 caracteres'
case "$EVO_INSTANCE" in
  */*|*\?*|*#*|*%*)
    erro 'EVO_INSTANCE contem caractere que altera o caminho da URL' ;;
esac
[[ ! "$EVO_INSTANCE" =~ [[:cntrl:]] ]] || erro 'EVO_INSTANCE contem caractere de controle'
EVO_INSTANCE_SEGMENT="$(jq -rn --arg valor "$EVO_INSTANCE" '$valor | @uri')" ||
  erro 'nao foi possivel codificar EVO_INSTANCE'

if [[ "$DRY" == 1 ]]; then
  STATE="${STATE}.dry"  # testes nunca alteram os alertas de producao
  LOCK="${LOCK}.dry"    # testes nao bloqueiam a instancia de producao
  LOG="${LOG}.dry"      # testes nao misturam registros com producao
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
TOKEN_ALTERADO=0
if [[ "$DRY" == 0 ]]; then
  [[ "$EVO_TOKEN" != *$'\n'* && "$EVO_TOKEN" != *$'\r'* && "$EVO_TOKEN" != *'"'* && "$EVO_TOKEN" != *'\'* ]] || erro 'EVO_TOKEN contem caracteres invalidos para o arquivo curl'
  # Compara dentro do shell, sem colocar a chave na lista de argumentos.
  if [[ ! -f "$CURLRC" ]] ||
     ! cmp -s "$CURLRC" <(printf 'header = "apikey: %s"\nheader = "Content-Type: application/json"\n' "$EVO_TOKEN"); then
    TOKEN_ALTERADO=1
  fi
  printf 'header = "apikey: %s"\nheader = "Content-Type: application/json"\n' "$EVO_TOKEN" > "$CURLRC" || erro 'falha ao gravar credenciais do curl'
  chmod 600 "$CURLRC" 2>/dev/null || true
fi

ler() { sed -n "s/^$1=//p" "$STATE" 2>/dev/null | tail -1; }
grava() {
  local k="$1" v="$2" tmp linha nome alterado=0
  local -A campos=()
  # Mantem a ultima ocorrencia valida de cada chave, descartando linhas ruins.
  while IFS= read -r linha || [[ -n "$linha" ]]; do
    if [[ ! "$linha" =~ ^([A-Za-z_][A-Za-z_0-9]*)=(.*)$ ]]; then
      alterado=1; continue
    fi
    nome="${BASH_REMATCH[1]}"
    [[ ! ${campos[$nome]+existe} ]] || alterado=1
    campos["$nome"]="${BASH_REMATCH[2]}"
  done < "$STATE" || erro 'falha ao ler estado'
  # Mesmo valor não requer escrita, exceto se houver dados a normalizar.
  if [[ "$alterado" == 0 && ${campos[$k]+existe} && "${campos[$k]}" == "$v" ]]; then
    return 0
  fi
  campos["$k"]="$v"
  tmp="$(mktemp "${STATE}.XXXXXX")" || erro 'falha ao criar estado temporário'
  for nome in "${!campos[@]}"; do
    printf '%s=%s\n' "$nome" "${campos[$nome]}" >> "$tmp" ||
      { rm -f "$tmp"; erro 'falha ao escrever estado'; }
  done
  chmod 600 "$tmp" && mv -f "$tmp" "$STATE" ||
    { rm -f "$tmp"; erro 'falha ao persistir estado'; }
}

limpar_tentativas() {
  local evento="$1" k v
  for k in "proxima_${evento}" "falhas_${evento}"; do
    v="$(ler "$k")"
    [[ -z "$v" || "$v" == 0 ]] || grava "$k" 0
  done
}

pode_tentar() {
  local evento="$1" proxima
  proxima="$(ler "proxima_${evento}")"
  [[ "$proxima" =~ ^[0-9]{1,12}$ ]] || return 0
  (( $(date +%s) >= 10#$proxima ))
}

registrar_erro_envio() {
  local evento="$1" rc="$2" http="$3" falhas atraso motivo
  falhas="$(ler "falhas_${evento}")"
  [[ "$falhas" =~ ^[0-9]{1,3}$ ]] || falhas=0
  falhas=$(( 10#$falhas + 1 ))
  (( falhas > 20 )) && falhas=20
  # Requisicao com resposta perdida e incerta: espacamento maior.
  if [[ "$rc" == 28 ]]; then
    atraso=900
  else
    case "$http" in
      401|403) atraso=3600 ;;
      429) atraso=900 ;;
      5??|000|'')
        atraso=$(( 60 * (2 ** (falhas < 4 ? falhas - 1 : 3)) ))
        (( atraso > 300 )) && atraso=300 ;;
      *) atraso=120 ;;
    esac
  fi
  grava "falhas_${evento}" "$falhas"
  grava "proxima_${evento}" "$(( $(date +%s) + atraso ))"
  # Diagnóstico por código: não misturar stderr no HTTP nem registrar dados privados.
  case "$rc" in
    0) motivo='resposta HTTP sem sucesso' ;;
    3) motivo='URL inválida' ;;
    5) motivo='falha de resolução do proxy' ;;
    6) motivo='falha de resolução DNS' ;;
    7) motivo='falha ao estabelecer conexão' ;;
    28) motivo='tempo limite excedido' ;;
    35|51|60|77|83|90|91) motivo='falha de TLS ou certificado' ;;
    52|55|56) motivo='falha de comunicação com o servidor' ;;
    *) motivo='falha de transporte (consulte o código curl)' ;;
  esac
  log "ERRO evento=$evento curl=$rc http=${http:-sem-resposta} motivo=$motivo tentativa=$falhas espera=${atraso}s"
  [[ "$rc" == 28 ]] && log "AVISO evento=$evento resultado incerto; a API pode ter recebido a mensagem"
}

# A troca de chave invalida a espera por autenticacao, sem persistir hash de token.
if [[ "$TOKEN_ALTERADO" == 1 ]]; then
  for evento in baixo plugado cheio; do limpar_tentativas "$evento"; done
fi

envia() {
  local evento="$1" msg="$2" payload http rc
  if [[ "$DRY" == 1 ]]; then
    log "DRY evento=$evento msg=$msg"
    printf '[DRY] %s\n' "$msg"
    return 0
  fi
  payload="$(jq -cn --arg number "$DESTINO" --arg text "$msg" '{number:$number,text:$text}')" || return 1
  # -q deve ser a primeira opcao: ignora ~/.curlrc, mas preserva o -K privado.
  # Nao seguir redirecionamentos nem permitir outro protocolo de transporte.
  http="$(curl -q --proto "=$EVO_PROTO" --proto-redir "=$EVO_PROTO" \
    --max-redirs 0 -sS --connect-timeout 8 --max-time 25 -K "$CURLRC" \
    -X POST "$EVO_URL/message/sendText/$EVO_INSTANCE_SEGMENT" \
    --data-binary "$payload" -o /dev/null -w '%{http_code}' 2>/dev/null)"
  rc=$?
  if [[ "$rc" -eq 0 && "$http" =~ ^2[0-9][0-9]$ ]]; then
    log "OK evento=$evento http=$http msg=$msg"
    limpar_tentativas "$evento"
    return 0
  fi
  registrar_erro_envio "$evento" "$rc" "$http"
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
  read -r CAP STATUS FONTE ORIGEM <<< "$leitura"
  if [[ ! "$CAP" =~ ^[0-9]{1,3}$ ]] || (( 10#$CAP > 100 )); then
    log "leitura invalida cap='$CAP' status='$STATUS'"
    sleep "$INTERVALO"
    continue
  fi

  # Uma leitura válida encerra a sequência de falhas, mesmo sem envio.
  if [[ -n "$ULTIMO_LOG" ]]; then log 'leitura da bateria recuperada'; fi

  # A fonte conectada/desconectada so e confirmada com dado explicito.
  # PLUGGED_-1 indica informacao desconhecida, jamais conexao confirmada.
  PLUGADO='desconhecido'
  CONEXAO_CONFIRMADA=0
  case "$FONTE" in
    PLUGGED_AC|PLUGGED_USB|PLUGGED_WIRELESS|PLUGGED_DOCK)
      PLUGADO=1; CONEXAO_CONFIRMADA=1 ;;
    UNPLUGGED)
      PLUGADO=0
      [[ "$ORIGEM" == API || "$ORIGEM" == SYSFS_OFFLINE ]] && CONEXAO_CONFIRMADA=1 ;;
    PLUGGED_OTHER)
      PLUGADO=1
      [[ "$ORIGEM" == SYSFS_ONLINE ]] && CONEXAO_CONFIRMADA=1 ;;
  esac
  if [[ "$PLUGADO" == desconhecido ]]; then
    # Inferência da API não rearma o aviso de conexão.
    case "$STATUS" in
      CHARGING) PLUGADO=1 ;;
      FULL) [[ "$ORIGEM" == API ]] && PLUGADO=1 ;;
      DISCHARGING) PLUGADO=0 ;;
    esac
  fi

  if [[ "$PRIMEIRA" == 1 ]]; then
    # Nao avisa transicoes anteriores ao inicio; bateria baixa avisa ja.
    [[ "$PLUGADO" == 1 ]] && grava plugado_avisado 1
    (( 10#$CAP >= 10#$LIMIAR_CHEIO )) && grava cheio_avisado 1
    log "baseline cap=$CAP status=$STATUS fonte=$FONTE origem=$ORIGEM plugado=$PLUGADO confirmado=$CONEXAO_CONFIRMADA"
    PRIMEIRA=0
  fi

  # Mesmo sem fonte identificada, bateria baixa precisa gerar um aviso.
  # Com fonte conectada e DISCHARGING, avisar que a carga nao acompanha o uso.
  if (( 10#$CAP <= 10#$LIMIAR_BAIXO )) &&
     [[ "$PLUGADO" != 1 || "$STATUS" == DISCHARGING ]] &&
     [[ "$(ler baixo_avisado)" != 1 ]]; then
    if [[ "$PLUGADO" == 1 ]]; then
      renderizar_mensagem "$MSG_BAIXA_CONECTADO" "$CAP"
    elif [[ "$PLUGADO" == 0 ]]; then
      renderizar_mensagem "$MSG_BAIXA_DESCONECTADO" "$CAP"
    else
      renderizar_mensagem "$MSG_BAIXA_DESCONHECIDO" "$CAP"
    fi
    if pode_tentar baixo && envia baixo "$aviso"; then grava baixo_avisado 1; fi
  fi
  if (( 10#$CAP > 10#$LIMIAR_RESET )); then
    grava baixo_avisado 0
    limpar_tentativas baixo
  fi

  # O caminho alternativo admite inferência coerente, mas não a apresenta como certeza.
  if [[ "$PLUGADO" == 1 ]] &&
     [[ "$CONEXAO_CONFIRMADA" == 1 || ( "$ORIGEM" == SYSFS_INFERIDO && "$STATUS" == CHARGING ) ]] &&
     (( 10#$CAP < 10#$LIMIAR_CHEIO )) && [[ "$(ler plugado_avisado)" != 1 ]]; then
    if [[ "$CONEXAO_CONFIRMADA" == 1 ]]; then
      renderizar_mensagem "$MSG_CARREGADOR_CONECTADO" "$CAP"
    else
      renderizar_mensagem "$MSG_CARREGADOR_INFERIDO" "$CAP"
    fi
    if pode_tentar plugado && envia plugado "$aviso"; then grava plugado_avisado 1; fi
  fi
  # Fonte indeterminada nunca rearma. No fallback, DISCHARGING é só uma inferência.
  if [[ "$PLUGADO" == 0 ]] &&
     [[ "$CONEXAO_CONFIRMADA" == 1 || ( "$ORIGEM" == SYSFS_INFERIDO && "$STATUS" == DISCHARGING ) ]]; then
    grava plugado_avisado 0
    limpar_tentativas plugado
  fi

  if (( 10#$CAP >= 10#$LIMIAR_CHEIO )) && [[ "$(ler cheio_avisado)" != 1 ]]; then
    renderizar_mensagem "$MSG_CARGA_COMPLETA" "$CAP"
    if pode_tentar cheio && envia cheio "$aviso"; then grava cheio_avisado 1; fi
  fi
  if (( 10#$CAP < 10#$LIMIAR_CHEIO_RESET )); then
    grava cheio_avisado 0
    limpar_tentativas cheio
  fi

  grava ultimo "$CAP"
  sleep "$INTERVALO"
done
