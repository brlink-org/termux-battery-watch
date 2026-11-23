#!/usr/bin/env bash
# Testes independentes com dados falsos; nunca acessam WhatsApp ou Android real.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/termux-battery-status" <<'MOCK'
#!/bin/sh
printf '%s\n' "$MOCK_BATTERY"
MOCK
cat > "$TMP/bin/sleep" <<'MOCK'
#!/bin/sh
n=$(cat "$MOCK_CYCLES" 2>/dev/null || echo 0)
n=$((n+1)); echo "$n" > "$MOCK_CYCLES"
if [ "$n" -ge 3 ]; then kill -TERM "$PPID" 2>/dev/null || :; fi
/bin/sleep 0.01
MOCK
cat > "$TMP/bin/curl" <<'MOCK'
#!/bin/bash
[[ "$1" == -q ]] || exit 90
[[ " $* " == *' -K '* ]] || exit 91
printf 'called\n' >> "$MOCK_CALLS"
printf '%s' "${MOCK_HTTP:-201}"
MOCK
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"
pass=0
run_case() {
  local label="$1" cap="$2" status="$3" plugged="$4" dry="$5" http="$6" url="$7" instance="$8"
  local home="$TMP/$label"
  mkdir -p "$home"
  export HOME="$home" MOCK_CYCLES="$home/cycles" MOCK_CALLS="$home/calls"
  export MOCK_HTTP="$http" DRY="$dry"
  export MOCK_BATTERY
  MOCK_BATTERY="$(jq -cn --arg s "$status" --arg p "$plugged" --argjson c "$cap" '{percentage:$c,status:$s,plugged:$p}')"
  cat > "$home/.battery-watch.conf" <<CONF
EVO_URL="$url"
EVO_TOKEN="chave_ficticia"
EVO_INSTANCE="$instance"
DESTINO="5571999999999"
INTERVALO=1
CONF
  bash "$ROOT/battery-watch.sh" >"$home/output" 2>"$home/erro" || :
  pass=$((pass+1))
}
assert_contains() { grep -qF -- "$2" "$1" || { echo "FALHA: esperado $2 em $1"; exit 1; }; }
assert_absent() { [[ ! -e "$1" ]] || { echo "FALHA: arquivo inesperado $1"; exit 1; }; }
assert_count() {
  local n=0
  [[ ! -f "$1" ]] || n="$(wc -l < "$1")"
  [[ "$n" == "$2" ]] || { echo "FALHA: $1 tem $n linhas, esperado $2"; exit 1; }
}
run_case desconhecido 20 NOT_CHARGING UNKNOWN 1 201 https://evo.example.com cirinho
assert_contains "$TMP/desconhecido/.battery-watch.log.dry" 'Nao foi possivel confirmar'
assert_absent "$TMP/desconhecido/.battery-watch.log"
assert_absent "$TMP/desconhecido/calls"
run_case menos_um 20 DISCHARGING PLUGGED_-1 1 201 https://evo.example.com cirinho
assert_contains "$TMP/menos_um/.battery-watch.log.dry" 'Bateria baixa'
run_case conectada 20 NOT_CHARGING PLUGGED_AC 1 201 https://evo.example.com cirinho
if grep -q 'DRY evento=' "$TMP/conectada/.battery-watch.log.dry"; then exit 1; fi
run_case sucesso 20 DISCHARGING UNPLUGGED 0 201 https://evo.example.com cirinho
assert_count "$TMP/sucesso/calls" 1
assert_contains "$TMP/sucesso/.battery-watch.state" 'baixo_avisado=1'
run_case falha500 20 DISCHARGING UNPLUGGED 0 500 https://evo.example.com cirinho
assert_count "$TMP/falha500/calls" 1
assert_contains "$TMP/falha500/.battery-watch.state" 'proxima_baixo='
run_case sem_https 20 DISCHARGING UNPLUGGED 0 201 http://203.0.113.1:8080 cirinho
assert_absent "$TMP/sem_https/calls"
assert_contains "$TMP/sem_https/erro" 'HTTP e permitido apenas'
run_case nome_invalido 20 DISCHARGING UNPLUGGED 0 201 https://evo.example.com 'a/b'
assert_absent "$TMP/nome_invalido/calls"
assert_contains "$TMP/nome_invalido/erro" 'EVO_INSTANCE'
echo "OK — $pass cenários de integração simulada, sem chamadas externas."
