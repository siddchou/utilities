# claude-local: Claude Code on local models (Ubuntu)

Runs [Claude Code](https://claude.com/claude-code) against a locally served model
(LM Studio, Bionic, llama.cpp, vLLM — anything with an OpenAI-compatible API).
```
Claude Code -> normalizer (:4001) -> LiteLLM (:4000) -> your model server (e.g. :1234)
```

- **LiteLLM** translates Anthropic's Messages API to OpenAI chat completions
  (streaming + tool calls both directions). It binds to `127.0.0.1` only, and
  `drop_params: true` is set so unsupported client params are dropped instead of
  failing the request.
- **claude-bionic-normalizer.py** merges Claude Code's mid-conversation system
  messages into a single leading system message, which Qwen-family chat
  templates require ("System message must be at the beginning"). It also
  sanitizes tool `input_schema`s (strips `$schema`/`propertyNames`, merges
  string-only `anyOf` unions) and drops Anthropic extended-thinking params, so
  clients like Claude Desktop's Cowork mode work against strict local servers.

## Install

```bash
./setup-claude-local.sh --test        # everything + end-to-end prompt test
```

No sudo required. Installs Claude Code (native installer) and LiteLLM (pip, user
site), writes config/wrapper/systemd units under `~/.config` and `~/.local/bin`,
and installs two systemd user services (`litellm-bionic`, `claude-normalizer`).
If Claude Desktop is installed the bridges run on demand with it (see below);
otherwise they auto-start at login.

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

## Use with Claude Desktop (optional)

Claude Desktop has an undocumented "enterprise gateway" (3P) mode that routes all
inference through a custom Anthropic-compatible endpoint. Point it at the
normalizer to chat with your local model in the desktop app:

1. Add an alias for the model id Desktop requests to `~/.config/litellm/config.yaml`,
   then restart the bridge (`systemctl --user restart litellm-bionic`):
   ```yaml
     - model_name: claude-sonnet-4-5
       litellm_params:
         model: openai/<MODEL_ID>
         api_base: <API_BASE>
         api_key: local-bridge
   ```
2. Create/merge `~/.config/Claude-3p/claude_desktop_config.json`:
   ```json
   { "deploymentMode": "3p" }
   ```
3. Create `~/.config/Claude-3p/configLibrary/<uuid>.json` (any uuid):
   ```json
   {
     "inferenceProvider": "gateway",
     "inferenceCredentialKind": "static",
     "inferenceGatewayApiKey": "local-bridge",
     "inferenceGatewayAuthScheme": "bearer",
     "inferenceGatewayBaseUrl": "http://localhost:4001/",
     "inferenceModels": [ { "name": "claude-sonnet-4-5", "labelOverride": "claude-sonnet-4-5" } ]
   }
   ```
4. Register it in `~/.config/Claude-3p/configLibrary/_meta.json`: set `"appliedId"` to the
   uuid and add `{ "id": "<uuid>", "name": "claude-sonnet-4-5" }` to `entries`.
5. Fully quit Claude Desktop (tray → Quit) and relaunch; pick `claude-sonnet-4-5` —
   that's your local model answering through the bridge chain.

Revert by removing `"deploymentMode": "3p"` and deleting the configLibrary entry.
The mode is undocumented (see https://github.com/mohitsoni48/Claude-Desktop-Router);
a future app update may change or remove it.

### Bridge auto-starts with Claude Desktop

When `claude-desktop` is installed, re-running the setup script switches the bridges
from login auto-start to on demand: they start when Claude Desktop launches and stop
again when the last instance exits. This installs:

- `~/.local/bin/claude-desktop-local` — wrapper that starts the two user services
  (systemd, or a nohup fallback), waits for health on :4000/:4001, then runs
  `/usr/bin/claude-desktop`; on exit it stops the services unless another desktop
  instance is still running. Log: `~/claude-desktop-local.log`.
- `~/.local/bin/claude-desktop` — symlink to the wrapper, so terminal launches go
  through it too (`~/.local/bin` is first on PATH).
- `~/.local/share/applications/com.anthropic.Claude.desktop` — user-level override of
  the system menu entry (same name wins), pointing at the wrapper.

Revert: delete those three files and run
`systemctl --user enable litellm-bionic claude-normalizer`.

## Manage

```bash
./setup-claude-local.sh --remove                          # uninstall generated files + services
systemctl --user status litellm-bionic claude-normalizer  # health
journalctl --user -u litellm-bionic -f                    # logs (or ~/litellm-bionic.log)
tail -f ~/claude-desktop-local.log                        # Claude Desktop launch wrapper log
```

Note: your model server must be running and serving the configured model.

Re-running this setup script reinstalls the fixed normalizer (the embedded heredoc matches
the standalone file).
