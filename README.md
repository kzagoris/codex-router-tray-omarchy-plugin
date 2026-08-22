# Codex Router Tray

Codex Router Tray is a bar widget for the [Omarchy](https://omarchy.org)
shell. It shows the status of
[codex-router](https://github.com/duolahypercho/codex-router), its usage, its
providers, and its models. It also gives you the maintenance commands.

The widget replaces the Tauri desktop companion on Linux. It adds no second
runtime and no Rust toolchain. The code is QML inside the Omarchy shell
(Quickshell).

Plugin id: `kzagoris.codex-router-tray` · Version 0.2.0 · License: MIT

<p align="center">
  <img src="preview.png" alt="The four panel views: Status, Usage, Providers, and Models" width="900">
</p>

## What you get

**The bar pill** shows a router glyph with a status dot. The color of the dot
gives the state of the router.

| Dot | Meaning |
|---|---|
| green | The router runs and is idle. |
| amber (it pulses) | The router routes one or more active requests. |
| red | The router is degraded, or it has an error. |
| gray | The router is off, or the widget cannot get access to it. |

An optional label shows the provider that routes the traffic now. On a left
bar or a right bar, the widget puts one icon in each line, like the clock.

**The panel** opens with a left click. It has four views: Status, Usage,
Providers, and Models. Each view keeps the same three parts:

- **The hero line** shows the live state (`RUNNING · V0.4.0-BETA.4`,
  `GENERATING · 2 ACTIVE`, `OFFLINE`, or `DEGRADED: …`).
- **The status box** shows guidance when a problem occurs. The router is off,
  the caller key is absent, or a provider is degraded.
- **The footer** has a manual refresh button and the time of the last update.

The panel does not obey the single-column style of the first-party widgets.
This is deliberate. ADR 0001 in the development repository gives the reason.

The shell keeps your selected view for the session. The view stays the same
after you close the panel and open it again. A shell restart sets the view
back to Status.

### Status

The Status view has the three modes of the router: login-free routing, signed
routing, and compaction of old tool results. Below the modes, it shows the
live activity and the maintenance commands: Restart, Update, Fix, and Open
web panel.

<p align="center">
  <img src="docs/screenshots/status.png" alt="The Status view with modes, activity, and maintenance" width="380">
</p>

### Usage

The Usage view shows the tokens of one provider. A switcher selects the
provider. The bars show the tokens for each of the last 7 days. The rows
below show the part of the total that each provider used. If you turn on the
ChatGPT quota cards, they show here.

<p align="center">
  <img src="docs/screenshots/usage.png" alt="The Usage view with tokens for each day and for each provider" width="380">
</p>

### Providers

The Providers view shows each provider in the catalog with a badge and a
toggle. The badge tells you if the provider is configured. The toggle turns
the provider on or off.

"Add key" and "Sign in" open the web panel of the router. You never type a
credential into the plugin.

<p align="center">
  <img src="docs/screenshots/providers.png" alt="The Providers view with badges and toggles" width="380">
</p>

### Models

The Models view shows each model in the catalog that an enabled provider
gives. The rows are in groups by provider, and you can collapse each group.

A sub-switcher selects what the row toggle changes: the visibility in the
picker, or the eligibility as a subagent. Each label carries both counts.
Thus a click cannot change the wrong setting.

A picker row shows the slug of the model. A subagent row shows the proof:
`Proven v2`, `Untested`, `Working…`, or `Error: …`. Put the mouse pointer on
an error to see the reason from the router.

A model that is hidden from the picker cannot be a subagent. Its toggle is
inert, and the badge gives the cause. A click on that toggle moves you to the
Picker sub-view. The widget does not make the model visible without your
permission.

"Show all", "Hide all", "Subagents on", and "Subagents off" operate on the
full list or on one provider. They use the bulk verbs of the router: one
command, not one command for each model.

The toggles are optimistic. A toggle changes immediately, and repeated clicks
on the same model become one command. If a command fails, the toggle goes
back and the panel shows the message from the router. When the queue is
empty, the view reads the data one time and reconciles.

<p align="center">
  <img src="docs/screenshots/models.png" alt="The Models view with picker visibility and subagent eligibility" width="380">
</p>

**A middle click** opens the browser panel of the router at its capability
URL. Use it for the large flows. The web panel is the sanctioned surface of
the router for secrets.

## What you need

- Omarchy 4.x (Quattro shell / Quickshell).
- codex-router, installed and in operation. Start it with
  `systemctl --user start codex-router`. The payload shapes agree with
  v0.4.0-beta.4.
- Node.js on the PATH. Mutations start the control CLI of the router
  (`node …/src/control.mjs`).
- The caller secret of the router at `~/.codex/codex-router/caller-secret`.
  The router makes this file. If the file is lost, `./bin/doctor --fix` makes
  it again.

## Install

Clone this repository into your plugins directory. Then turn on the plugin:

```sh
git clone https://github.com/kzagoris/codex-router-tray-omarchy-plugin.git \
  ~/.config/omarchy/plugins/kzagoris.codex-router-tray
omarchy plugin enable kzagoris.codex-router-tray right
```

To update the plugin later, do these two commands:

```sh
git -C ~/.config/omarchy/plugins/kzagoris.codex-router-tray pull
omarchy restart shell
```

The folder must be a real copy. A plugin folder must not contain a symlink.
`omarchy plugin validate` refuses a symlink, and the marketplace refuses it
too.

## Settings

The settings of the widget are in `~/.config/omarchy/shell.json`, in the
layout entry of the widget:

```json
{ "id": "kzagoris.codex-router-tray", "port": 4202 }
```

| Key | Default | Description |
|---|---|---|
| `healthIntervalSec` | `4` | Interval of the health poll in seconds (2 to 60) |
| `dataIntervalSec` | `30` | Interval of the usage refresh in seconds, while the widget can read the data (15 to 600) |
| `showProviderText` | `"Icon only"` | The bar label: `"Icon only"` or `"Provider name"` |
| `port` | `4202` | The port of the router. If it is empty, the widget uses `MODEL_ROUTER_PORT`, then `4202` |
| `stateDir` | `""` | The directory that holds `caller-secret`. If it is empty, the widget uses `~/.codex/codex-router` |
| `sourceRoot` | `""` | The checkout of the router for the control CLI. If it is empty, the widget uses `~/.local/share/codex-router` |
| `accountUsage` | `"Off"` | The ChatGPT quota cards. The upstream call is slow, thus the default is `"Off"` |

## Commands

```sh
omarchy-shell shell summon kzagoris.codex-router-tray '{}'   # open
omarchy-shell shell hide kzagoris.codex-router-tray          # close
omarchy-shell shell toggle kzagoris.codex-router-tray
omarchy-shell kzagoris.codex-router-tray refresh             # re-poll now
```

Put the focus on the panel. Then push `R` to refresh the data, Escape to
close the panel, or Tab to move to the next panel.

## How it works

- `GET http://127.0.0.1:<port>/health` needs no authentication and is cheap.
  It drives the dot, the hero line, and the activity.
- `POST /_codex-router/<caller-secret>/panel/invoke` is the same bridge that
  the browser panel of the router injects. The widget uses only the read-only
  allowlist: `control_snapshot`, `account_usage`, `provider_usage`,
  `provider_setup`, and `local_models`.
- The widget reads the caller secret one time into memory. It never writes
  the secret to a log or to a file, and it removes the secret from each URL
  that it shows.
- Mutations run the control CLI of the router (`src/control.mjs` with
  `MODEL_ROUTER_TARGET=codex`). The widget runs one command at a time and
  shows a busy label or an error. After each command, it reads the data
  again.
- The model toggles queue behind the same runner. Repeated intents for one
  model become one command. When the queue is empty, the view reconciles
  against one read. The bulk commands operate on the full list or on one
  provider.

All the traffic stays on the loopback interface. No credential goes through
the plugin.

## Problems and fixes

| Problem | Fix |
|---|---|
| The dot is gray and the panel shows "Router offline" | `systemctl --user start codex-router` |
| The panel shows "Caller key missing or unreadable" | Run `./bin/doctor --fix` in the checkout of the router |
| A toggle or a button gives an error | Make sure that Node is on the PATH and that `sourceRoot` points to the checkout of the router |
| The widget is absent from the gallery | `omarchy plugin list --json \| jq '.[] \| select(.id=="kzagoris.codex-router-tray")'` |
| The journal shows QML errors | `qs log -p "$OMARCHY_PATH/shell" --tail 100` |

## Development

Work on a clone in your plugins directory. Then examine it in that location:

```sh
omarchy plugin validate ~/.config/omarchy/plugins/kzagoris.codex-router-tray
qs log -p "$OMARCHY_PATH/shell" --tail 100   # QML errors
```

A change in the body of a QML file that compiles reloads when you save the
file. A change to an import, or a new file, needs `omarchy restart shell`.

## Changelog

### 0.2.0

- **The Models view.** It shows each model in the catalog that an enabled
  provider gives, in groups by provider. A sub-switcher selects the picker
  visibility or the subagent eligibility. The view has proof badges, the
  interlock between the two settings, and the bulk commands.
- **The panel became a switcher over four views.** Status, Usage, Providers,
  and Models share one hero line, one status box, and one footer. The shell
  keeps the selected view for the session.
- **Optimistic toggles.** A click changes the toggle immediately. Repeated
  clicks on one model become one command. A failure puts the toggle back with
  the message from the router. The view then reconciles against one read.
- **Correct release of the automatic refresh.** Each exit from the mutation
  runner releases it, and this includes the abort when the router is off. A
  toggle whose read is still in transit stays when you leave the view.
- **The compaction of old tool results** moved into the modes in the Status
  view, where a routing mode belongs.
- The control CLI wrapper accepts a slug with a provider, for example
  `opencode-free/big-pickle`.
- A test harness with no dependencies (the test runner of Node) examines the
  pure logic modules. Captured router snapshots feed the tests. A change to a
  payload thus makes a test fail, not the panel.

### 0.1.0

The first public release. It has the bar pill with the live health dot. Its
panel has the modes, the activity, the usage, and the provider controls. The
panel also has the maintenance commands and the link to the web panel.

## Not included, on purpose

- An overlay in the style of the macOS Dynamic Island. The Linux tray has no
  island.
- Flows that install a local model and show the progress. The web panel does
  this.
- Other languages. The plugin is in English only.

## License

MIT — see [LICENSE](LICENSE).
