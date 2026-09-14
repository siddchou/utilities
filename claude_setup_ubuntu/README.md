# claude-local: Claude Code on local models (Ubuntu)

Runs [Claude Code](https://claude.com/claude-code) against a locally served model
(LM Studio, Bionic, llama.cpp, vLLM — anything with an OpenAI-compatible API).

```
Claude Code -> normalizer (:4001) -> LiteLLM (:4000) -> your model server (e.g. :1234)
```

- **LiteLLM** translates Anthropic's Messages API to OpenAI chat completions
  (streaming + tool calls both directions).
- **claude-bionic-normalizer.py** merges Claude Code's mid-conversation system
  messages into a single leading system message, which Qwen-family chat
  templates require ("System message must be at the beginning").

## Install

```bash
./setup-claude-local.sh --test        # everything + end-to-end prompt test
```

No sudo required. Installs Claude Code (native installer) and LiteLLM (pip, user
site), writes config/wrapper/systemd units under `~/.config` and `~/.local/bin`,
and enables two systemd user services (`litellm-bionic`, `claude-normalizer`)
that auto-start at login.

## Configure a different model / server

```bash
API_BASE=http://localhost:8080/v1 \
MODEL_ID=llama-3.1-8b-instruct \
FRIENDLY_NAME=llama31 \
./setup-claude-local.sh --test
```

Defaults: `http://localhost:1234/v1`, model id `qwen3.8-27b@q4_k_xl`,
friendly name `qwen3-8-27b`.

## Usage

```bash
claude-local                  # interactive, default 256k context window
claude-local 135k             # ...with a 135k context window (k = x1024)
claude-local -p "your prompt" # one-shot / headless
```

## Manage

```bash
./setup-claude-local.sh --remove                          # uninstall generated files + services
systemctl --user status litellm-bionic claude-normalizer  # health
journalctl --user -u litellm-bionic -f                    # logs (or ~/litellm-bionic.log)
```

Note: your model server must be running and serving the configured model.
