#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# Ollama LLM Server Health Check
# ═══════════════════════════════════════════════════════════════

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# .env에서 읽기
PORT=11434
MODEL_NAME="unknown"
MODEL_TAG="unknown"
MODEL_ALIAS="unknown"
USE_MLX=""
if [[ -f "$ENV_FILE" ]]; then
    PORT=$(grep "^PORT=" "$ENV_FILE" | cut -d= -f2 | tr -d '"' || echo "11434")
    MODEL_NAME=$(grep "^MODEL_NAME=" "$ENV_FILE" | cut -d= -f2 | tr -d '"' || echo "unknown")
    MODEL_TAG=$(grep "^MODEL_TAG=" "$ENV_FILE" | cut -d= -f2 | tr -d '"' || echo "unknown")
    MODEL_ALIAS=$(grep "^MODEL_ALIAS=" "$ENV_FILE" | cut -d= -f2 | tr -d '"' || echo "unknown")
    USE_MLX=$(grep "^USE_MLX=" "$ENV_FILE" | cut -d= -f2 | tr -d '"' || echo "")
fi

WATCH=false
JSON=false
TIMEOUT=5

while [[ $# -gt 0 ]]; do
    case "$1" in
        -w|--watch) WATCH=true; shift ;;
        -j|--json)  JSON=true; shift ;;
        -t|--timeout) TIMEOUT="$2"; shift 2 ;;
        -h|--help)
            echo "사용법: $0 [-w|--watch] [-j|--json] [-t TIMEOUT]"
            exit 0 ;;
        *) shift ;;
    esac
done

check_service() {
    local port="$1"
    local code=$(curl -sf -o /dev/null -w '%{http_code}' \
        --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
        "http://localhost:${port}/v1/models" 2>/dev/null || echo "000")
    echo "$code"
}

check_inference() {
    local port="$1"
    local tag="$2"
    # 간단한 inference 테스트 (timeout 짧게)
    local start_time=$(date +%s%N)
    local code=$(curl -sf -o /dev/null -w '%{http_code}' \
        --connect-timeout "$TIMEOUT" --max-time "$((TIMEOUT * 6))" \
        "http://localhost:${port}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"${tag}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":5}" \
        2>/dev/null || echo "000")
    local end_time=$(date +%s%N)
    local latency_ms=$(( (end_time - start_time) / 1000000 ))
    echo "${code}:${latency_ms}"
}

do_check() {
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    local code=$(check_service "$PORT")

    if [[ "$JSON" == true ]]; then
        python3 -c "
import json
result = {
    'timestamp': '$ts',
    'model': '$MODEL_ALIAS',
    'tag': '$MODEL_TAG',
    'port': $PORT,
    'healthy': '$code' == '200',
    'http_code': int('$code'),
    'mlx_enabled': '$USE_MLX' == '1'
}
print(json.dumps(result, indent=2, ensure_ascii=False))
" 2>/dev/null
        return
    fi

    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Ollama Health Check  │  ${ts}${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    if [[ "$code" == "200" ]]; then
        echo -e "  ${GREEN}✓${NC} API (${MODEL_ALIAS}): OK  — :${PORT}"
        [[ "$USE_MLX" == "1" ]] && echo -e "  ${GREEN}✓${NC} MLX backend enabled"

        # 모델 정보 출력
        curl -sf "http://localhost:${PORT}/v1/models" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('data', []):
    print(f\"    → {m['id']}\")
" 2>/dev/null || true
    elif [[ "$code" == "000" ]]; then
        echo -e "  ${RED}✗${NC} API (${MODEL_ALIAS}): UNREACHABLE  — :${PORT}"
    else
        echo -e "  ${YELLOW}⚠${NC} API (${MODEL_ALIAS}): HTTP ${code}  — :${PORT}"
    fi

    echo ""
}

if [[ "$WATCH" == true ]]; then
    while true; do
        clear
        do_check
        echo -e "  ${BLUE}(5초 간격 │ Ctrl+C 종료)${NC}"
        sleep 5
    done
else
    do_check
fi
