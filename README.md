# llm-server-template-ollama

Config-driven LLM serving on Apple Silicon using [Ollama](https://ollama.com) with **MLX backend** (v0.19+).

OpenAI-compatible API, launchd auto-start, health monitoring.

## Why Ollama + MLX?

Ollama 0.19+ introduced an **MLX backend** on Apple Silicon that delivers:
- ~1.6× faster prefill
- ~1.9× faster decode
- Unified memory efficiency via Apple's MLX framework

Activate via `OLLAMA_USE_MLX=1` env var. Requires M1+ with 32GB+ unified memory.

## Requirements

- macOS (Apple Silicon, M1+ / 32GB+ unified memory)
- [Ollama](https://ollama.com) 0.19+ (MLX backend)
- [uv](https://github.com/astral-sh/uv)
- Python 3.12+

## Quick Start

```bash
# 1. 의존성 설치 (현재는 pyyaml만)
uv sync

# 2. 서버 시작 (모델 없으면 자동 ollama pull)
./start.sh qwen3.6-35b-a3b

# 3. 부팅 시 자동 시작 등록
./start.sh qwen3.6-35b-a3b --install
```

## Usage

### start.sh
```bash
./start.sh <model>                  # 백그라운드 시작
./start.sh <model> --follow         # Foreground 모드
./start.sh <model> --port 11435     # 포트 변경
./start.sh <model> --install        # 시작 + launchd 등록
./start.sh --list                   # 사용 가능한 config 목록
```

### stop.sh
```bash
./stop.sh                           # 서버 종료
./stop.sh status                    # 상태 확인
./stop.sh logs                      # tail -f /tmp/ollama-server.log
./stop.sh restart                   # 재시작
./stop.sh uninstall                 # launchd 서비스 제거
```

### health_check.sh
```bash
./health_check.sh                   # 단일 체크
./health_check.sh --watch           # 5초 간격 모니터링
./health_check.sh --json            # JSON 출력
```

## Config

`configs/` 디렉토리에 YAML을 추가하면 모델 설정을 관리할 수 있습니다.

```yaml
# configs/qwen3.6-35b-a3b.yaml
model:
  name: "qwen3.6-35b-a3b"           # config 식별자 (파일명과 일치 권장)
  tag: "qwen3.6:35b-a3b"            # Ollama 레지스트리 태그 (ollama pull ...)
  alias: "qwen3.6-35b-a3b"          # API 응답 표시 이름 (tag와 동일해도 OK)
  description: "Qwen3.6 35B MoE — 3B active, MLX backend"

server:
  host: "0.0.0.0"
  port: 11434
  mlx: true                         # OLLAMA_USE_MLX=1 설정
  keep_alive: "30m"                 # 모델 메모리 상주 시간
  num_ctx: 16384                    # context window (옵션)
```

## API

OpenAI-compatible API를 제공합니다.

```bash
# 모델 목록
curl http://localhost:11434/v1/models

# Chat Completions
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.6:35b-a3b",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

Python (OpenAI SDK):
```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:11434/v1", api_key="ollama")
response = client.chat.completions.create(
    model="qwen3.6:35b-a3b",
    messages=[{"role": "user", "content": "Hello"}],
)
```

## MLX Backend 확인

서버 시작 후 로그에서 확인:
```bash
./stop.sh logs | grep -i mlx
# 또는
grep -i mlx /tmp/ollama-server.log
```

또는 환경변수 확인:
```bash
ps eww -p $(pgrep ollama) | tr ' ' '\n' | grep OLLAMA_USE_MLX
```

## Architecture

```
Client → :11434 (ollama serve, MLX backend)
            │
            └── ~/.ollama/models (blob store, managed by ollama)
```

Alias proxy 없음 — Ollama가 tag 기반 model id를 그대로 반환합니다.

## Project Structure

```
├── configs/                    # 모델 설정 YAML
├── scripts/
│   ├── parse_config.py         # config → .env 변환
│   └── generate_plist.sh       # launchd plist 생성/등록
├── start.sh                    # 서버 시작 + 모델 pull
├── stop.sh                     # 서버 종료/상태/로그
└── health_check.sh             # 헬스체크
```

## Troubleshooting

- **MLX backend 비활성**: Ollama 버전 0.19 미만. `brew upgrade ollama` 후 재시작.
- **모델 pull 느림**: Ollama 레지스트리 대용량 모델은 GB 단위. 네트워크 확인.
- **포트 충돌**: `lsof -i :11434`로 확인. 다른 ollama 인스턴스 종료 후 재시작.
- **메모리 부족 (<32GB)**: MLX backend 요구사항. 더 작은 모델 사용.
