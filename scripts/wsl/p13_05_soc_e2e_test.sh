#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
exec python3 -B "$repo/verification/directed/p13_aes_soc/p13_05_evidence_guard.py" "$@"
