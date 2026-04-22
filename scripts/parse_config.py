#!/usr/bin/env python3
"""
Config → .env 변환기
configs/*.yaml을 읽어 ollama 서버용 .env 파일을 생성합니다.
"""

import sys
import yaml
from pathlib import Path


def parse_config(config_path: str) -> dict:
    """YAML 설정을 읽어 .env 변수로 변환"""
    with open(config_path, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)

    model = cfg.get("model", {})
    server = cfg.get("server", {})

    env = {
        "MODEL_NAME": model.get("name", "default"),
        "MODEL_TAG": model.get("tag", ""),
        "MODEL_ALIAS": model.get("alias", model.get("name", "default")),
        "MODEL_DESCRIPTION": model.get("description", ""),
        "HOST": server.get("host", "0.0.0.0"),
        "PORT": str(server.get("port", 11434)),
        "USE_MLX": "1" if server.get("mlx", True) else "",
        "KEEP_ALIVE": str(server.get("keep_alive", "30m")),
        "NUM_CTX": str(server.get("num_ctx", 16384)),
    }

    if not env["MODEL_TAG"]:
        print("ERROR: model.tag is required in config")
        sys.exit(1)

    return env


def write_env(env: dict, output_path: str = ".env"):
    """딕셔너리를 .env 파일로 저장"""
    lines = []
    for k, v in env.items():
        if " " in v or '"' in v:
            v_escaped = v.replace('"', '\\"')
            lines.append(f'{k}="{v_escaped}"')
        else:
            lines.append(f"{k}={v}")

    with open(output_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    return output_path


def main():
    if len(sys.argv) < 2:
        print("Usage: python parse_config.py <config.yaml> [output.env]")
        sys.exit(1)

    config_path = sys.argv[1]
    output_path = sys.argv[2] if len(sys.argv) > 2 else ".env"

    if not Path(config_path).exists():
        print(f"ERROR: Config not found: {config_path}")
        sys.exit(1)

    env = parse_config(config_path)
    write_env(env, output_path)

    print(f"Model:  {env['MODEL_NAME']}")
    print(f"Tag:    {env['MODEL_TAG']}")
    print(f"Alias:  {env['MODEL_ALIAS']}")
    print(f"Server: {env['HOST']}:{env['PORT']}")
    print(f"MLX:    {'enabled' if env['USE_MLX'] else 'disabled'}")
    print(f"Env:    {output_path}")


if __name__ == "__main__":
    main()
