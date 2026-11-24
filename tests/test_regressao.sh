#!/usr/bin/env bash
# Executa testes em ambiente isolado; Python é dependência apenas de desenvolvimento.
set -euo pipefail
exec python3 "$(dirname "${BASH_SOURCE[0]}")/test_regressao.py" "$@"
