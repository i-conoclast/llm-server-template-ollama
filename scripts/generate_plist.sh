#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# LaunchAgent plist 생성 스크립트 (Ollama + MLX)
# .env를 읽어서 plist를 생성하고 launchd에 등록합니다.
# ═══════════════════════════════════════════════════════════════

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
PLIST_NAME="com.ollama.server"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
OLLAMA_PATH="$(which ollama)"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ ! -f "$ENV_FILE" ]]; then
    log_error ".env 파일 없음. 먼저 ./start.sh <model> 을 실행하세요."
    exit 1
fi

source "$ENV_FILE"

if [[ -z "$MODEL_TAG" ]]; then
    log_error ".env에 MODEL_TAG가 없습니다."
    exit 1
fi

if [[ -z "$OLLAMA_PATH" ]]; then
    log_error "ollama 명령을 찾을 수 없습니다. brew install ollama"
    exit 1
fi

# 기존 서비스 중지
launchctl bootout gui/$(id -u)/${PLIST_NAME} 2>/dev/null || true
sleep 1

log_info "plist 생성: ${PLIST_PATH}"
log_info "Model: ${MODEL_ALIAS} (tag: ${MODEL_TAG})"
log_info "Port: ${PORT:-11434}"
[[ "$USE_MLX" == "1" ]] && log_info "MLX backend: enabled"

cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${OLLAMA_PATH}</string>
        <string>serve</string>
    </array>

    <key>WorkingDirectory</key>
    <string>${SCRIPT_DIR}</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>OLLAMA_HOST</key>
        <string>${HOST:-0.0.0.0}:${PORT:-11434}</string>
        <key>OLLAMA_USE_MLX</key>
        <string>${USE_MLX:-0}</string>
        <key>OLLAMA_KEEP_ALIVE</key>
        <string>${KEEP_ALIVE:-30m}</string>
    </dict>

    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/tmp/ollama-server.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/ollama-server.log</string>
</dict>
</plist>
PLIST

# 로그 symlink
ln -sf /tmp/ollama-server.log "${SCRIPT_DIR}/server.log"

# 등록
launchctl bootstrap gui/$(id -u) "$PLIST_PATH" 2>&1
log_info "launchd 서비스 등록 완료"

# 모델 메모리 로드 트리거 (launchd가 ollama를 띄운 뒤 최초 요청으로 모델 로드)
log_info "모델 메모리 로드 트리거 대기 (최대 30초)..."
for i in {1..15}; do
    if curl -sf "http://localhost:${PORT:-11434}/v1/models" > /dev/null 2>&1; then
        curl -sf "http://localhost:${PORT:-11434}/api/generate" \
            -d "{\"model\":\"${MODEL_TAG}\",\"prompt\":\"\",\"stream\":false}" \
            > /dev/null 2>&1 || true
        log_info "모델 로드 트리거 완료"
        break
    fi
    sleep 2
done
