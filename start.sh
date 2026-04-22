#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# Ollama LLM Server Start Script (MLX backend)
# ═══════════════════════════════════════════════════════════════
# 시작:        ./start.sh qwen3.6-35b-a3b
# 포트 변경:   ./start.sh qwen3.6-35b-a3b --port 11435
# Foreground:  ./start.sh qwen3.6-35b-a3b --follow
# 서비스등록:  ./start.sh qwen3.6-35b-a3b --install
# ═══════════════════════════════════════════════════════════════

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/configs"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
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
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ── 도움말 ──
show_help() {
    cat << EOF
${BLUE}═══════════════════════════════════════════════════════════════${NC}
${BLUE}  Ollama LLM Server Start Script (MLX backend)${NC}
${BLUE}═══════════════════════════════════════════════════════════════${NC}

${CYAN}사용법:${NC}
    $0 <model_name> [옵션]

${CYAN}명령어:${NC}
    <model_name>        모델 시작 (configs/ 디렉토리 기준)
    --list, -l          사용 가능한 모델 목록
    --help, -h          이 도움말

${CYAN}옵션:${NC}
    --port PORT         포트 오버라이드
    --follow, -f        로그 따라가기 (foreground)
    --install           launchd 서비스로 등록 (부팅 시 자동 시작)

${CYAN}예시:${NC}
    $0 qwen3.6-35b-a3b                    # 모델 시작
    $0 qwen3.6-35b-a3b --port 11435       # 포트 변경
    $0 qwen3.6-35b-a3b -f                 # Foreground 모드
    $0 qwen3.6-35b-a3b --install          # 시작 + launchd 등록

${CYAN}사용 가능한 모델:${NC}
$(ls -1 "${CONFIG_DIR}"/*.yaml 2>/dev/null | xargs -I {} basename {} .yaml | sed 's/^/    /' || echo "    (설정 파일 없음)")

EOF
}

# ── 모델 목록 ──
list_models() {
    echo ""
    echo -e "${BLUE}사용 가능한 모델:${NC}"
    echo ""
    for config_file in "${CONFIG_DIR}"/*.yaml; do
        if [[ -f "$config_file" ]]; then
            local name=$(basename "$config_file" .yaml)
            local desc=$(uv run python -c "
import yaml
with open('$config_file') as f:
    cfg = yaml.safe_load(f)
print(cfg.get('model', {}).get('description', ''))
" 2>/dev/null || echo "")
            local tag=$(uv run python -c "
import yaml
with open('$config_file') as f:
    cfg = yaml.safe_load(f)
print(cfg.get('model', {}).get('tag', ''))
" 2>/dev/null || echo "")
            printf "  ${GREEN}%-25s${NC} %s\n" "$name" "$desc"
            printf "  %-25s tag: %s\n" "" "$tag"
            echo ""
        fi
    done
}

# ── Ollama 설치 확인 ──
check_ollama() {
    if ! command -v ollama >/dev/null 2>&1; then
        log_error "ollama 명령이 없습니다. 설치: brew install ollama"
        exit 1
    fi
    local version=$(ollama --version 2>&1 | head -1 | awk '{print $NF}')
    log_info "Ollama 버전: ${version}"
}

# ── 기존 서버 확인 ──
check_existing() {
    # launchd 서비스 확인
    if launchctl list | grep -q "$PLIST_NAME" 2>/dev/null; then
        local current_model=$(grep "^MODEL_NAME=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"')
        log_warn "기존 launchd 서비스 실행중: ${current_model:-unknown}"
        echo ""
        read -p "  서버를 교체할까요? (y/N): " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then
            log_info "기존 서비스 종료중..."
            launchctl bootout gui/$(id -u)/${PLIST_NAME} 2>/dev/null || true
            pkill -x ollama 2>/dev/null || true
            sleep 2
        else
            log_info "취소되었습니다."
            exit 0
        fi
        return
    fi

    # PID 파일 확인
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            local current_model=$(grep "^MODEL_NAME=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"')
            log_warn "기존 서버 실행중: ${current_model} (PID: ${pid})"
            echo ""
            read -p "  서버를 교체할까요? (y/N): " confirm
            if [[ "$confirm" =~ ^[yY]$ ]]; then
                log_info "기존 서버 종료중..."
                kill "$pid" 2>/dev/null
                pkill -x ollama 2>/dev/null || true
                sleep 2
            else
                log_info "취소되었습니다."
                exit 0
            fi
        fi
        rm -f "$PID_FILE"
    fi

    # 기존 ollama serve 프로세스 (PID 추적 밖)
    if pgrep -x ollama >/dev/null 2>&1; then
        log_warn "다른 ollama 프로세스가 실행중입니다."
        read -p "  종료할까요? (y/N): " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then
            pkill -x ollama 2>/dev/null || true
            sleep 2
        fi
    fi
}

# ── 모델 manifest 존재 확인 (서버 실행 불필요) ──
model_manifest_exists() {
    local tag="$1"
    # tag 포맷: name:version → ~/.ollama/models/manifests/registry.ollama.ai/library/name/version
    local name="${tag%%:*}"
    local version="${tag##*:}"
    [[ -f "$HOME/.ollama/models/manifests/registry.ollama.ai/library/${name}/${version}" ]]
}

# ── 모델 pull (없을 때) ──
ensure_model_pulled() {
    local tag="$1"
    if model_manifest_exists "$tag"; then
        log_info "모델 확인: ${tag}"
        return 0
    fi

    log_info "모델이 없습니다. 다운로드: ${tag}"
    log_warn "대용량 모델은 수 GB — 시간이 걸릴 수 있음."

    # pull 은 ollama serve 가 실행 중이어야 함 → 임시 서버 띄우고 pull 후 종료
    local temp_server_started=false
    if ! pgrep -x ollama >/dev/null 2>&1; then
        log_info "임시 ollama 서버 시작 (pull 용)..."
        OLLAMA_HOST=127.0.0.1:11434 ollama serve > /tmp/ollama-temp-pull.log 2>&1 &
        temp_server_started=true
        # 준비 대기
        for _ in {1..30}; do
            if curl -sf http://127.0.0.1:11434/ > /dev/null 2>&1; then break; fi
            sleep 1
        done
    fi

    ollama pull "$tag"
    local pull_rc=$?

    if [[ "$temp_server_started" == true ]]; then
        pkill -x ollama 2>/dev/null || true
        sleep 2
    fi

    if [[ $pull_rc -ne 0 ]]; then
        log_error "모델 pull 실패: ${tag}"
        exit 1
    fi
}

# ── plist 생성 + 등록 ──
install_service() {
    log_info "launchd 서비스 등록중..."
    bash "${SCRIPTS_DIR}/generate_plist.sh"
}

# ── 서버 준비 대기 ──
wait_for_ready() {
    local port="$1"
    local max_wait="${2:-120}"
    local waited=0

    log_info "서버 준비 대기중... (포트: ${port})"

    while [[ $waited -lt $max_wait ]]; do
        if curl -sf "http://localhost:${port}/v1/models" > /dev/null 2>&1; then
            echo ""
            log_info "서버 준비 완료!"
            return 0
        fi

        sleep 2
        waited=$((waited + 2))
        printf "\r  대기중... %d/%d초  " "$waited" "$max_wait"
    done

    echo ""
    log_warn "준비 시간 초과 (${max_wait}초)"
    return 1
}

# ── MLX backend 확인 ──
verify_mlx() {
    local port="$1"
    sleep 2  # 로그 flush
    if grep -iqE "(mlx|metal)" "$LOG_FILE" 2>/dev/null; then
        log_info "MLX backend 활성 감지"
    else
        log_warn "MLX backend 활성 여부 불명 (로그 확인: tail $LOG_FILE)"
    fi
}

# ── 메인 ──
main() {
    local model_name=""
    local port_override=""
    local follow=false
    local install=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)    show_help; exit 0 ;;
            --list|-l)    list_models; exit 0 ;;
            --port)       port_override="$2"; shift 2 ;;
            --follow|-f)  follow=true; shift ;;
            --install)    install=true; shift ;;
            -*)           log_error "알 수 없는 옵션: $1"; exit 1 ;;
            *)            model_name="$1"; shift ;;
        esac
    done

    if [[ -z "$model_name" ]]; then
        show_help
        exit 1
    fi

    local config_file="${CONFIG_DIR}/${model_name}.yaml"
    if [[ ! -f "$config_file" ]]; then
        log_error "설정 파일을 찾을 수 없습니다: ${config_file}"
        list_models
        exit 1
    fi

    check_ollama
    check_existing

    # Config → .env 변환
    log_info "설정 로드: ${model_name}"
    uv run python "${SCRIPTS_DIR}/parse_config.py" "$config_file" "$ENV_FILE"

    # .env 읽기
    source "$ENV_FILE"

    # 모델 확보
    ensure_model_pulled "$MODEL_TAG"

    # 포트 오버라이드
    if [[ -n "$port_override" ]]; then
        PORT="$port_override"
        sed -i '' "s/^PORT=.*/PORT=${port_override}/" "$ENV_FILE"
        log_info "포트 오버라이드: ${port_override}"
    fi

    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Ollama LLM Server Starting: ${MODEL_NAME}${NC}"
    echo -e "${BLUE}  Tag:   ${MODEL_TAG}${NC}"
    echo -e "${BLUE}  Alias: ${MODEL_ALIAS}${NC}"
    echo -e "${BLUE}  Host:  ${HOST}:${PORT}${NC}"
    [[ "$USE_MLX" == "1" ]] && echo -e "${BLUE}  MLX:   enabled (OLLAMA_USE_MLX=1)${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    if [[ "$install" == true ]]; then
        install_service
        wait_for_ready "$PORT" 120
        verify_mlx "$PORT"
    elif [[ "$follow" == true ]]; then
        log_info "Foreground 모드 (Ctrl+C로 종료)"
        OLLAMA_USE_MLX="$USE_MLX" \
        OLLAMA_HOST="${HOST}:${PORT}" \
        OLLAMA_KEEP_ALIVE="$KEEP_ALIVE" \
            ollama serve
    else
        OLLAMA_USE_MLX="$USE_MLX" \
        OLLAMA_HOST="${HOST}:${PORT}" \
        OLLAMA_KEEP_ALIVE="$KEEP_ALIVE" \
            ollama serve \
            >> "$LOG_FILE" 2>&1 &

        echo $! > "$PID_FILE"
        log_info "서버 시작됨 (PID: $(cat $PID_FILE))"
        wait_for_ready "$PORT" 120
        verify_mlx "$PORT"

        # 첫 호출로 모델 메모리 로드 트리거
        log_info "모델 메모리 로드 중 (첫 호출 지연)..."
        curl -sf "http://localhost:${PORT}/api/generate" \
            -d "{\"model\":\"${MODEL_TAG}\",\"prompt\":\"\",\"stream\":false}" \
            > /dev/null 2>&1 || true
    fi

    echo ""
    echo -e "${GREEN}  ┌──────────────────────────────────────────────────┐${NC}"
    echo -e "${GREEN}  │  Model:   ${MODEL_ALIAS}$(printf '%*s' $((28 - ${#MODEL_ALIAS})) '')│${NC}"
    echo -e "${GREEN}  │  API:     http://localhost:${PORT}/v1$(printf '%*s' $((19 - ${#PORT})) '')│${NC}"
    echo -e "${GREEN}  │  Models:  http://localhost:${PORT}/v1/models$(printf '%*s' $((12 - ${#PORT})) '')│${NC}"
    echo -e "${GREEN}  └──────────────────────────────────────────────────┘${NC}"
    echo ""
}

main "$@"
