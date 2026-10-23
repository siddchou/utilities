# deepseek_harness_launch

Double-click launchers for a DeepSeek Harness source checkout on Ubuntu/GNOME. One entry starts the Web UI in its own browser window — and stops it again (double-click while running, or just close that window) — plus an entry to rebuild the artifacts.

The scripts run `dsh web` straight from your checkout's source (node + tsx), so no packaged app is needed. The checkout path is a setting (`DSH_REPO` in `launch.conf`), defaulting to `/home/schou08/Applications/deepseek-harness`.

## Files

| File | Purpose |
|---|---|
| `dsh-web.sh` | Toggle entry: not running → starts `dsh web` and opens a dedicated, watchable browser window; already running → stops (closes the window + graceful shutdown) |
| `dsh-stop.sh` | Stop script: graceful `SIGTERM`, then `SIGKILL` after 20s. Not a menu entry — run by the window watcher and from a terminal |
| `dsh-build.sh` | Build entry: `pnpm run build:artifacts`; `--full` (terminal only) runs the complete `pnpm run build` |
| `install-desktop-entry.sh` | Links the two entries into `~/.local/share/applications`, removes any older Stop entry, and enables double-click launch in Files; `--uninstall` reverses it |
| `dsh-common.sh` | Shared helpers: PATH/node discovery, artifact checks, port probe, notifications |
| `deepseek-harness*.desktop` | GNOME entries (absolute paths to this folder and the default checkout) |
| `launch.conf.example` | Copy to `~/.config/deepseek-harness/launch.conf`: `DSH_REPO`, `DSH_PORT`, `DSH_BROWSER`, `DSH_NODE`, `DSH_EXTRA_ARGS`, `DSH_READY_TIMEOUT` |

## Install

```bash
./install-desktop-entry.sh                 # register the two entries (replaces any older 3-icon install)
./install-desktop-entry.sh --uninstall     # remove them again
```

Then search "DeepSeek Harness" in the app grid, or double-click a `.desktop` file in this folder (right-click → **Allow Launching** once if Files complains).

The checkout itself must be prepared first:

```bash
cd /home/schou08/Applications/deepseek-harness
pnpm install
pnpm run build        # full; or double-click DeepSeek Harness (Build) for just the web artifacts
```

## Usage

- **DeepSeek Harness** — one entry, two states:
  - Not running → starts the server and opens a dedicated Chrome/Firefox window on `http://127.0.0.1:3080/?token=…`.
  - Already running → stops it (closes the window, graceful shutdown).
  - Closing that window also stops the server within a few seconds: a watcher runs the stop script when the browser process exits. The window uses its own profile under `~/.local/state/deepseek-harness-launcher/browser-profile`, so it is an independent process even while your normal browser session is open.
- If some other server already listens on the port, the entry opens that URL and touches nothing.
- Pick where the agent works with **Choose workspace** in the Web UI; the start directory is only a default location.
- Model API key: **Settings → Models** in the Web UI, or `DEEPSEEK_API_KEY=…` in `~/.dsh/.env`.
- After every `git pull`: double-click **DeepSeek Harness (Build)**, then toggle off and on again.

## Why it starts from the repo root

A source launch runs node through tsx, which resolves the checkout's tsconfig `paths` (source-level imports such as `@deepseek-ai/cordis`) from the process working directory. Any other cwd falls back to built bundles that lack const-enum exports and crash at boot (`FiberState`). The launcher therefore always starts node in `$DSH_REPO`.

## State

| Path | Purpose |
|---|---|
| `~/.local/state/deepseek-harness-launcher/web.log` | Server output, including the launch token (0600, trimmed past 2 MiB) |
| `~/.local/state/deepseek-harness-launcher/web.pid` | Pid of the launcher-started server |
| `~/.local/state/deepseek-harness-launcher/browser.pid` | Pid of the dedicated UI window's browser process |
| `~/.local/state/deepseek-harness-launcher/browser-profile/` | That window's browser profile (kept across starts for cookies/localStorage) |
| `~/.local/state/deepseek-harness-launcher/build.log` | Build output |

## Troubleshooting

| Symptom | Check |
|---|---|
| Dialog: Node.js was not found | Install Node 22.19+/24+, or set `DSH_NODE`. A desktop session does not read `~/.bashrc`. |
| Dialog: built Web artifacts are not present | Double-click DeepSeek Harness (Build), then start again. Run it after every `git pull`. |
| Dialog names the wrong checkout path | Set `DSH_REPO` in `launch.conf` to your actual checkout folder. |
| Files says the launcher is untrusted | Right-click the desktop file once → **Allow Launching**, or re-run the install script. |
| Nothing opens after a long wait | `tail -40 ~/.local/state/deepseek-harness-launcher/web.log` |
| Port already serving something | The entry opens that port and tells you. Stop the other server, or set `DSH_PORT` in `launch.conf`. |
| Closed the window but the server keeps running | Auto-stop needs a trackable browser (Chrome-family/Firefox). Check the start notification; set `DSH_BROWSER` in `launch.conf`, or double-click the entry again to stop. |
| Browser shows 401 | Open the `dsh web: http://127.0.0.1:<port>/?token=…` line from `web.log`; the token is per server process. |
| Moved or renamed this folder | The desktop files hold absolute paths; re-run the install script from the new location and delete stale entries. |
