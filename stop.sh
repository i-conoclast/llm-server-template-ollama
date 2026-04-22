#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# Ollama LLM Server Stop / Status Script
# ═══════════════════════════════════════════════════════════════

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
PID_FILE="${SCRIPT_DIR}/.server.pid"
LOG_FILE="/tmp/ollama-server.log"
PLIST_NAME="com.ollama.server"

# ── 색상 ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }

show_help() {
    cat << EOF
${BLUE}═══════════════════════════════════════════════════════════════${NC}
${BLUE}  Ollama LLM Server Stop / Status Script${NC}
${BLUE}═══════════════════════════════════════════════════════════════${NC}

${CYAN}사용법:${NC}
    $0 [명령어]

${CYAN}명령어:${NC}
    stop (기본)     서버 종료
    status          현재 상태 확인
    logs            로그 보기 (tail -f)
    restart         재시작
    uninstall       launchd 서비스 제거

EOF
}

is_launchd_running() {
    launchctl list 2>/dev/null | grep -q "$PLIST_NAME"
}

status() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Ollama LLM Server Status${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    local model_name="unknown"
    local model_tag="unknown"
    local model_alias="unknown"
    local port="11434"
    local use_mlx=""
    if [[ -f "$ENV_FILE" ]]; then
        model_name=$(grep "^MODEL_NAME=" "$ENV_FILE" | cut -d= -f2 | tr -d '"')
        model_tag=$(grep "^MODEL_TAG=" "$ENV_FILE" | cut -d= -f2 | tr -d '"')
        model_alias=$(grep "^MODEL_ALIAS=" "$ENV_FILE" | cut -d= -f2 | tr -d '"')
        port=$(grep "^PORT=" "$ENV_FILE" | cut -d= -f2 | tr -d '"')
        use_mlx=$(grep "^USE_MLX=" "$ENV_FILE" | cut -d= -f2 | tr -d '"')
    fi

    echo -e "  ${CYAN}[LLM]${NC}"

    local running=false
    if is_launchd_running; then
        local info=$(launchctl list | grep "$PLIST_NAME")
        local pid=$(echo "$info" | awk '{print $1}')
        local exit_code=$(echo "$info" | awk '{print $2}')
        echo -e "  ${GREEN}●${NC} Service: launchd (PID: ${pid}, exit: ${exit_code})"
        running=true
    elif [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo -e "  ${GREEN}●${NC} Process: running (PID: $(cat "$PID_FILE"))"
        running=true
    elif pgrep -x ollama >/dev/null 2>&1; then
        echo -e "  ${GREEN}●${NC} Process: ollama running (PID: $(pgrep -x ollama | head -1))"
        running=true
    fi

    if [[ "$running" == true ]]; then
        echo -e "    Model: ${model_alias} (tag: ${model_tag})"
        echo -e "    Port:  ${port}"
        [[ "$use_mlx" == "1" ]] && echo -e "    MLX:   enabled"

        if curl -sf "http://localhost:${port}/v1/models" > /dev/null 2>&1; then
            echo -e "  ${GREEN}●${NC} API: responding"
            curl -sf "http://localhost:${port}/v1/models" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('data', []):
    print(f\"    → {m['id']}\")
" 2>/dev/null || true
        else
            echo -e "  ${YELLOW}●${NC} API: not ready yet"
        fi

        # MLX backend 로그 흔적
        if grep -iqE "(mlx|metal)" "$LOG_FILE" 2>/dev/null; then
            echo -e "  ${GREEN}●${NC} MLX backend trace in logs"
        fi
    else
        echo -e "  ${RED}●${NC} Process: stopped"
    fi

    echo ""

    echo -e "  ${CYAN}[Memory]${NC}"
    local mem_total=$(sysctl -n hw.memsize | awk '{printf "%.0f", $1/1024/1024/1024}')
    local mem_used=$(vm_stat | awk '
        /Pages active/ {a=$NF}
        /Pages wired/ {w=$NF}
        /Pages occupied by compressor/ {c=$NF}
        END {
            gsub(/\./,"",a); gsub(/\./,"",w); gsub(/\./,"",c);
            printf "%.1f", (a+w+c)*4096/1024/1024/1024
        }')
    echo "    Total: ${mem_total}GB | Used: ~${mem_used}GB"
    echo ""

    echo -e "  ${CYAN}[Ollama models cached]${NC}"
    ollama list 2>/dev/null | tail -n +2 | head -10 | awk '{printf "    %s (%s)\n", $1, $3$4}'
    echo ""
}

stop_server() {
    # launchd 서비스 중지
    if is_launchd_running; then
        log_info "launchd 서비스 종료중..."
        launchctl bootout gui/$(id -u)/${PLIST_NAME} 2>/dev/null || true
        sleep 1
    fi

    # PID 파일로 종료
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
        fi
        rm -f "$PID_FILE"
    fi

    # 남은 ollama 프로세스
    if pgrep -x ollama >/dev/null 2>&1; then
        pkill -x ollama 2>/dev/null || true
    fi
    sleep 1
    log_info "서버 종료 완료"
}

main() {
    local cmd="${1:-stop}"

    case "$cmd" in
        --help|-h)
            show_help
            ;;
        status)
            status
            ;;
        logs)
            if [[ -f "$LOG_FILE" ]]; then
                tail -50 -f "$LOG_FILE"
            else
                echo "로그 파일 없음: $LOG_FILE"
            fi
            ;;
        restart)
            stop_server
            sleep 1
            if [[ -f "$ENV_FILE" ]]; then
                local model_name=$(grep "^MODEL_NAME=" "$ENV_FILE" | cut -d= -f2 | tr -d '"')
                log_info "재시작: ${model_name}"
                "${SCRIPT_DIR}/start.sh" "$model_name" --install
            else
                log_warn ".env 파일 없음 — ./start.sh <model> 을 실행하세요"
            fi
            ;;
        uninstall)
            stop_server
            local plist_path="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
            if [[ -f "$plist_path" ]]; then
                rm -f "$plist_path"
                log_info "plist 제거 완료: ${plist_path}"
            fi
            ;;
        stop|*)
            stop_server
            ;;
    esac
}

main "$@"
