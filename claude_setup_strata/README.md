# claude-strata: Claude Code + Claude Desktop on a local Strata server (Ubuntu)

The Strata port of `../claude_setup_ubuntu` (the Bionic/LM Studio stack). Same
goal — run Anthropic's apps against a model you serve yourself — but the proxy
chain is gone, because Strata speaks Anthropic's protocol natively.

```
Claude Code    --------------------------------->  Strata  (http://127.0.0.1:47831/v1/messages)
Claude Desktop -> strata-shim (:4001) -> Strata   (only Desktop still needs the hop)
```

Verified on this machine: Claude Code **2.1.307** → Strata **0.1.46.3** serving
`unsloth-ud-q4_k_xl` (Qwen3.8-Flash-Next UD-Q4_K_XL, 262144-token context) —
prompts, `tool_use` blocks, `tool_result` round-trips, and SSE streaming all work.

## Why the LiteLLM bridge and the normalizer were dropped

Bionic (llama.cpp) only speaks the OpenAI API, so the old stack needed LiteLLM
to translate Anthropic Messages → OpenAI chat completions, plus a normalizer for
Qwen chat-template quirks. Strata's server already serves the **Anthropic
Messages API** on `/v1/messages`, tested by Strata itself against Claude Code
(`strata connect claude-code` lists "messages + tools; tested (Claude Code
2.1.302)"). Probing this server confirmed:

| Behavior | Result on Strata |
| --- | --- |
| `POST /v1/messages`, `stream: true` | proper Anthropic SSE (`message_start`, `content_block_delta`, `thinking_delta`, `message_stop`) |
| Tool definitions → `tool_use` + `stop_reason: tool_use` | works; `tool_result` round-trip continues the turn |
| Mid-conversation `role: system` messages (Claude Code ≥ 2.1) | accepted, no "System message must be at the beginning" |
| Strict / exotic tool `input_schema` (`$schema`, `propertyNames`, string-only `anyOf`) | accepted, no 400 |
| Unknown top-level params (`thinking`, `output_config`, `metadata`) | accepted and ignored |
| Auth | loopback listener, key not enforced (any value works) |

So the only thing left to do is hand Claude Code the right env — which is what
the `claude-strata` wrapper does.

## Install

```bash
./setup-claude-strata.sh --test
```

No sudo. It checks the Strata server, installs Claude Code (native installer),
and writes `~/.local/bin/claude-strata`. Re-run any time; it is idempotent.

Claude Desktop is optional and **does** need root, so run it yourself in a
terminal (my shell cannot escalate privileges):

```bash
sudo ./install-claude-desktop.sh      # Anthropic apt repo -> /usr/bin/claude-desktop
./setup-claude-strata.sh --desktop    # then wire its 3p gateway to Strata (no sudo)
```

`--write-settings` additionally merges the same env into `~/.claude/settings.json`
so a plain `claude` launch uses Strata too. Without it only `claude-strata` is
affected, which is usually what you want.

## Configure a different server / model

```bash
STRATA_URL=http://127.0.0.1:8080 STRATA_MODEL=qwen3-coder STRATA_CONTEXT=131072 \
./setup-claude-strata.sh --test
```

| Variable | Default | Notes |
| --- | --- | --- |
| `STRATA_URL` | `http://127.0.0.1:47831` | a trailing `/v1` is stripped for you |
| `STRATA_MODEL` | discovered from `/v1/models` | must be an id the server reports, or it 400s |
| `STRATA_KEY` | `strata-local` | unused by the loopback server, sent as bearer |
| `STRATA_CONTEXT` | from `~/.config/strata/presets` (else 32768) | drives auto-compaction |
| `STRATA_MAX_OUTPUT_TOKENS` | `4096` | thinking tokens count toward this |
| `SHIM_PORT` | `4001` | Desktop shim |
| `SHIM_THINKING` | `keep` | `off` forces `thinking: {"type":"disabled"}` on Desktop requests: no thinking block, so reasoning stops eating the `max_tokens` budget and the answer starts as text. `keep` passes the app's choice through |
| `DESKTOP_MODEL` | `claude-sonnet-4-6` | must exist in Desktop's bundled catalog |

## Usage

```bash
claude-strata                  # interactive, context Strata was started with (262144 here)
claude-strata 135k             # ...with a 135k window (k = x1024, m = x1024^2)
claude-strata -p "your prompt" # one-shot / headless
```

The wrapper asks `/v1/models` on every launch, so **swapping the model in the
Strata app needs no re-run** — an id pinned at setup time would start 400ing.

## Use with Claude Desktop (`--desktop`)

Claude Desktop has an undocumented "enterprise gateway" (3p) mode that routes all
inference through a custom Anthropic-compatible endpoint. Two of its habits make
a raw Strata URL awkward, which is why `claude-strata-shim.py` exists:

1. **Discovery shape.** Desktop calls `GET /v1/models` and requires the
   *Anthropic* list shape (`data[].type == "model"`, `display_name`,
   `first_id`/`last_id`). Strata replies with the OpenAI shape → *"Gateway
   /v1/models returned an unexpected body"*.
2. **Model names.** The name in `inferenceModels` must exist in the app's
   *bundled* catalog or ConfigHealth rejects the config
   (`state: 'config_model_rejected'` in `~/.config/Claude-3p/logs/main.log`).
   Strata rejects unknown ids (`400 "Choose a loaded model ID."`).

The shim (:4001, loopback) answers `/v1/models` with a catalog of Desktop names
and rewrites the `model` field of every `/v1/messages` request to whatever
Strata actually has loaded; everything else streams through untouched. It also
answers `POST /v1/messages/count_tokens` locally (~4 chars/token estimate):
Strata has no such route, and unattended the app retries that 404 ~20 times per
turn.

### Verified on Claude Desktop 3.1623.1

Launching through the wrapper, `~/.config/Claude-3p/logs/main.log` shows:

```
[custom-3p] 3P mode active { provider: 'gateway' }
[custom-3p] Model discovery: skipped (inferenceModels obviates discovery); picker = 1 (inferenceModels)
[custom-3p] model-catalog: resolved { source: 'published', version: 2831, ... }
[custom-3p] ConfigHealth recomputed { state: 'healthy', provider: 'gateway' }
[custom-3p] inference apiHost=http://localhost:4001/
```

`claude-sonnet-4-6` **is** in catalog v2831 (ids include `claude-sonnet-5`,
`claude-opus-4-6`…`4-8`, `claude-haiku-5-5`), so the default name works as-is.
Decoding your own catalog is the way to check after an app update:

```bash
python3 -c 'import json,base64;d=json.load(open("%s/.config/Claude-3p/model-catalog/published.json"%__import__("os").environ["HOME"]));print(base64.b64decode(d["documentBytes"]).decode()[:200])'
```

Note that Desktop does **not** use the `claude` on your PATH for chat: it
downloads and spawns its own CLI (`~/.config/Claude-3p/claude-code/<ver>/…/claude`)
and injects the gateway settings into it. So local/Cowork sessions reach Strata
through the shim regardless of `~/.claude/settings.json`, and `--write-settings`
is not required for Desktop — it only changes what a plain `claude` in your own
terminal does.

What `--desktop` writes:

- `~/.config/claude-strata/claude-strata-shim.py` + systemd user unit
  `claude-strata-shim.service` (installed **disabled** — it comes up with Desktop)
- `~/.local/bin/claude-desktop-strata`: starts the shim, waits for
  `/healthz`, launches `/usr/bin/claude-desktop`, stops the shim when the last
  Desktop instance exits. Log: `~/claude-desktop-strata.log`
- `~/.local/bin/claude-desktop` → symlink to that wrapper, and
  `~/.local/share/applications/com.anthropic.Claude.desktop` so the app-menu
  entry goes through it too
- `~/.config/Claude-3p/claude_desktop_config.json` (`"deploymentMode": "3p"`),
  a `configLibrary/<uuid>.json` gateway entry pointing at
  `http://localhost:4001/`, and the matching `_meta.json` `appliedId`

Then fully quit Claude Desktop (tray → Quit), relaunch from the app menu or
`claude-desktop`, and pick **claude-sonnet-4-6** — that's Strata answering.

If your Desktop build rejects that name, decode the base64 `documentBytes` in
`~/.config/Claude-3p/model-catalog/published.json` and look under
`surfaces.*.model_selector_config[].models[].id`, then re-run with e.g.
`DESKTOP_MODEL=claude-opus-4-1 ./setup-claude-strata.sh --desktop`.

The mode is undocumented (see https://github.com/mohitsoni48/Claude-Desktop-Router);
a future app update may change or remove it.

## Manage

```bash
./setup-claude-strata.sh --remove                           # uninstall everything this script wrote
systemctl --user status claude-strata-shim                  # shim health
journalctl --user -u claude-strata-shim -f                  # shim logs
curl -s localhost:4001/healthz                              # {"status":"ok","model":"..."}
strata status                                               # Strata's own telemetry
strata connect claude-code --url http://127.0.0.1:47831 --check   # vendor's own prompt+tool check
```

## Troubleshooting

- **`claude-strata: no Strata server at http://127.0.0.1:47831`** — the model
  server is down. `strata launch` (guided, with the monitor) or
  `strata runtime start --preset NAME` (background service). The port changes
  per launch; pass `STRATA_URL`.
- **`400 {"error":{"message":"Choose a loaded model ID."}}`** — the model id
  doesn't match what's loaded. Check `curl -s $STRATA_URL/v1/models`; the
  wrapper normally self-heals by reading that on each launch.
- **`[claude-code:unrecognized_model]` on stderr** — harmless: Claude Code
  notices the id isn't an Anthropic one. Strata documents it too.
- **Replies stop mid-sentence, `stop_reason: max_tokens`** — thinking tokens
  count against `CLAUDE_CODE_MAX_OUTPUT_TOKENS` (4096). Raise it:
  `STRATA_MAX_OUTPUT_TOKENS=8192 claude-strata`.
- **Compacting every turn, or never** — the served context and
  `CLAUDE_CODE_MAX_CONTEXT_TOKENS` disagree. Verify the number the setup
  detected (`--test` prints it) against the Strata preset.
- **`/v1/messages/count_tokens` 404s** — Strata has no such route. Harmless for
  Claude Code (it estimates); the shim answers it for Desktop so the app stops
  retrying.
- **Clicking the Claude icon does nothing, and `~/claude-desktop-strata.log`
  fills with thousands of identical "Launching Claude Desktop" lines** — the
  launcher was pointing at itself. `~/.local/bin/claude-desktop` is a symlink to
  the launcher, so a target resolved through `PATH` re-ran the wrapper forever,
  and each unwinding level stopped the shim. Recover:
  `pkill -f '^bash .*claude-desktop-strata'`, then re-run
  `./setup-claude-strata.sh --desktop`. The wrapper now repairs or refuses a
  self-referencing target and hands off on nested launches, so it cannot loop.
  Check the target with `grep DESKTOP_BIN= ~/.local/bin/claude-desktop-strata`
  (expect `/usr/bin/claude-desktop`); force it with
  `CLAUDE_DESKTOP_BIN=/usr/bin/claude-desktop`.
- **Desktop: first reply takes 10-40 s** — prefill, not the shim. Measured on
  this box: time-to-first-token 9 s at ~1.5K prompt tokens, 38 s at ~7K. A
  Cowork prompt with ~20 tools is at the top of that range; the shim's own
  overhead is sub-millisecond.
- **Desktop: `[title-gen] direct request failed … aborted due to timeout`, then
  `title-gen CLI exited 1`** — the background titling call has a shorter timeout
  than a chat turn, so it loses the race against prefill. Cosmetic (the session
  still gets a fallback title). `SHIM_THINKING=off ./setup-claude-strata.sh
  --desktop` removes the thinking pass from Desktop requests, which cuts the
  latency and the token burn; it does not affect `claude-strata`.
- **Desktop: "Gateway /v1/models returned an unexpected body"** — Desktop is
  hitting Strata directly instead of the shim (`inferenceGatewayBaseUrl` must be
  `http://localhost:4001/`), or the shim is down: `systemctl --user restart claude-strata-shim`.
- **Desktop: `config_model_rejected`** — see the catalog-name note above.

## Differences from the Bionic setup

| | `claude_setup_ubuntu` (Bionic) | this (Strata) |
| --- | --- | --- |
| Chain | Claude Code → normalizer :4001 → LiteLLM :4000 → :1234 | Claude Code → Strata directly |
| Deps | Claude Code + LiteLLM (pip) + normalizer | Claude Code only |
| Services | `litellm-bionic`, `claude-normalizer` | none (shim only, for Desktop) |
| Mid-conversation system msgs | merged by the normalizer (Qwen template) | accepted natively |
| Extended thinking | dropped (LiteLLM rejected it) | passed through as `thinking` blocks |
| Model swap | re-run the script | automatic, read from `/v1/models` |
| Desktop shim | `claude-bionic-normalizer.py` | `claude-strata-shim.py` (name remap + model list + `count_tokens`) |

The original Bionic document is `../claude_setup_ubuntu/README.md`, kept in this
repo for the old stack.
