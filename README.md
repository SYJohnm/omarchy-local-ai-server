# Local AI Server

An Omarchy bar widget that starts, stops and monitors a local inference
server — **llama.cpp** (`llama-server`) or **ollama** — and shows live
prompt-processing (pp) and token-generation (tg) throughput while it works.

![tabs: Server · Model · Tuning · Stats](#)

## Why both backends look the same

ollama embeds llama.cpp, so both emit the same timing lines:

```
slot print_timing: id  0 | task 0 | prompt eval time = 521.34 ms / 11 tokens (  47.39 ms per token,  21.10 tokens per second)
slot print_timing: id  0 | task 0 |        eval time = 941.26 ms /  8 tokens ( 134.47 ms per token,   7.44 tokens per second)
```

One parser handles both, so the bar widget reads identically whichever
backend you pick.

They differ in resolution, and the widget is honest about it:

| | llama.cpp | ollama |
|---|---|---|
| tg tokens/sec | live | per completed request |
| pp tokens/sec | live | per completed request |
| pp % progress | live sweep | not available¹ |
| loaded model / VRAM split | `/slots` | `/api/ps` |

¹ ollama exposes no `/slots` equivalent over HTTP and logs no progress lines
at default verbosity.

## Install

```bash
git clone <this-repo> ~/.config/omarchy/plugins/sxy.local-ai-server
omarchy-shell shell rescanPlugins
omarchy plugin enable sxy.local-ai-server
omarchy bar move sxy.local-ai-server right
```

On first open the panel runs a short **setup**: pick a backend (with install
hints if none is found), choose which models folder to use (or create one), and
start from tuning recommended for your hardware or the backend's own defaults.
Nothing is assumed from anyone else's machine. Choices are saved to the
widget's settings in `shell.json`; run it again any time with **Setup…** at the
bottom of the panel.

Upgrading from an earlier id (`user.local-ai-server` or `user.llama-server`)?
Run `./migrate.sh` first — it rewrites the id in your bar layout (keeping the widget's
position) and copies your saved settings across. It backs up `shell.json`
and is safe to run twice.

## Requirements

At least one backend, plus `curl`, `python3`, `bash` and GNU `find`.
`systemd-run` is optional but recommended (see below). A Nerd Font is
assumed by the Omarchy bar itself.

## Settings

Everything auto-detects; the settings exist to override.

| Setting | Default | Meaning |
|---|---|---|
| `backend` | `llamacpp` | Which server to manage. Also switchable from the panel. |
| `binary` | auto | Preferred `llama-server`. Optional — every build is detected (see below); this one wins when a model is on Auto. |
| `ollamaBinary` | auto | `ollama` path. |
| `altBinary` | — | An extra `llama-server` build the scan would not find on its own. It joins the Build list. |
| `modelsDir` | auto | Probes `~/models`, `~/.cache/llama.cpp`, `~/.local/share/models`, LM Studio and jan directories. |

Runtime state (selected model, tuning values, host/port) lives in
`~/.local/state/omarchy/sxy.local-ai-server/settings.json`.

## Surviving `omarchy restart shell`

`omarchy restart shell` runs `quickshell kill`, which tears the widget down.
A server spawned as a plain child dies with it.

With **Survive restart** on (the default) the server is launched detached and
left running; the next widget instance re-adopts it after confirming it still
answers its health endpoint. Where `systemd-run` is available the server runs
as a transient user unit, which also routes its output to journald — that is
what lets throughput keep being read after the widget has been rebuilt.
Without systemd it falls back to `setsid`, which detaches but leaves no way to
read output back.

Turn the toggle off to get the old behaviour: the server is killed when the
widget goes away.

## llama.cpp builds

Many people run more than one `llama-server`: the distribution package, an
upstream checkout, and forks with features upstream does not have yet (extra KV
cache types, new speculative decoding). `llama_builds.py` finds them all — the
usual install paths, `PATH`, and any checkout under `~` with a `build/bin/` —
and identifies each by its git remote, commit, date and GPU backend (CUDA,
ROCm, Vulkan, …), plus the KV cache types its `--help` accepts.

With more than one build, the Model tab shows a **Build** picker. The choice is
part of the model's tuning profile, so a model that needs a fork keeps it while
the rest stay on upstream. **Auto** (the default) takes the first build that
accepts the model's cache types, preferring the `binary` setting, so picking a
fork-only cache type is enough to land on that fork. The KV cache dropdown
offers exactly what the chosen build supports, and flag suggestions come from
that build's own `--help`. Changing the build of a running model turns Stop
into Restart like any other change.

## Changing model or tuning

Model and tuning are launch flags, so applying a change restarts the server.
Only the server runs — there is no proxy or helper process alongside it.

Once the page no longer matches what is running (compared against the running
server's own command line, so undoing an edit puts Stop back), **Stop becomes
Restart** and the bar text gets a `•`. A small ■ next to it still stops.
Pressing Restart:

1. **waits** until no request is being processed (the button reads **Force**
   meanwhile — press it to restart right away, cutting off what is running);
2. **saves** the prompt cache (see below);
3. **stops** the server and **starts** it with the new launch line;
4. **restores** the prompt cache once the new server answers `/health`.

Clients get refused connections while the model loads, and should retry.

## Prompt cache

With **Keep prompt cache** on (the default, llama.cpp only), every slot's KV
cache is saved on Stop and Restart, and 20 s after the server goes idle
following a generation; it is restored at the next start. Re-reading a long
agent prompt is what makes a restart cost minutes on a small GPU — loading the
weights is not.

`slot_kv.py` does the saving and restoring through llama-server's own
`/slots` API, then exits. Files live in
`~/.local/state/omarchy/sxy.local-ai-server/slots/` as
`<model>.slot<N>.bin`; a save that wrote nothing never replaces a good file,
and a cache saved under different tuning is rejected by the server and the
start is simply cold.

## Installed backends

The Backend dropdown lists only the backends found on this machine — a
`llama-server` (or the alternate binary) for llama.cpp, an `ollama` binary for
ollama. A saved backend that is not installed moves to one that is. If neither
is found both stay listed, so the binary settings still make sense.

## Tuning sub-pages

Tuning holds seven rows per page and opens a numbered tab for the rest. Built-in
controls used to be pinned to the first page and only added parameters flowed
onto further ones — which was fine while the built-ins always fit, and stopped
being fine once the optional rows could put five more on the page. Past the
capacity the surplus simply ran off the bottom of the panel: rows that existed,
held values the next launch used, and could not be seen or reached.

Everything is counted now, in page order, and a row never splits across a
boundary — the projector's path field stays with the mode control that reveals
it. Seven is what the default set of rows already occupied, so a page that fits
today does not start paginating. Adding a parameter or restoring a row lands you
on whichever page it went to.

## Per-model tuning profiles

The Tuning page belongs to the selected model, not to the machine. A 35B MoE
wants layers pushed onto the CPU and a context that a 2B dense model would
never need; the same numbers cannot serve both.

There is no switch to arm first. Pick a model, change anything on Tuning, and
that model gets a profile holding the whole page — every value, the rows you
removed, the parameters you added. Pick another model and the page shows that
model's own values; models you have never tuned keep running on the shared
defaults, so a model you only ever start never has a profile written for it.

The header at the top of Tuning says which of the two you are looking at:

| Header | Meaning |
|---|---|
| `Profile · qwen3.6-35b` | This model has its own tuning. Edits stay here. |
| `Defaults · minicpm5-2b (edit to give it its own)` | Running on the shared defaults. The next edit starts a profile. |
| `Shared defaults — no model selected` | Editing the seed itself. |

**Reset** drops the current model's profile and puts it back on the shared
defaults. **Set default** makes the values on screen the seed for models that
have no profile yet, leaving existing profiles alone. In the model picker, a
model that carries a profile is marked `tuned`.

Profiles are keyed by backend as well as by model: llama.cpp tuning is argv
flags and ollama tuning is environment variables, so the two are never shared
even where they name the same weights. The shared defaults are per backend for
the same reason.

Profiles live in `settings.json` under `profiles`, keyed `backend::model`.
Nothing prunes them, so one for a model you have since deleted stays there —
harmless, and still waiting if the disk holding that model comes back.

Upgrading from a version without profiles: the single tuning set in your
settings file was tuned for the model it names, so it becomes that model's
profile *and* the shared default. Nothing about how that model launches
changes.

## Flags the plugin used to decide for you

Four things reached the launch line without ever appearing on a page: the
vision projector found next to a model, the `--no-mmproj-offload` that came
with it, the draft strategy picked from a model's metadata, and whatever
`extraArgs` held — a setting with no control at all, reachable only by editing
`settings.json`, and appended last so it beat every control that did exist.
The first three became rows; the fourth became rows too, one per argument.

Each is now a row on Tuning, and each is per model like the rest of the page:

| Row | Flag | Default |
|---|---|---|
| Slots (-np) | `--parallel N` | blank — the backend's own auto |
| Reasoning trace | `--reasoning-preserve` / `--no-…` | `default` — passes neither |
| Speculative | `--spec-type` | `none`, or the model's own draft type |
| Vision projector | `--mmproj` / `--no-mmproj`, `--mmproj-offload` | `auto`, offload `off` |
| Paste args | — splits into the rows above | blank |

These rows are off the page until asked for, from the same **+ Add parameter**
picker that adds any other flag — a control reading `default` in every position
is a row taking up space. Two of them put themselves there: a model with a
projector beside it shows the Vision row, and a draft type picked automatically
shows Speculative, because a decision made for you belongs where it can be
changed. Extra args do the same whenever they hold anything.

`--reasoning-preserve` and its siblings are tri-state, not toggles. llama.cpp
documents the default as *template default*, and passing `--no-reasoning-preserve`
is not the same as passing nothing: `default` leaves the chat template's own
choice, which is the only correct setting for a template that does not support
preserved reasoning at all. The same holds for `--jinja`, `--cont-batching` and
every other flag llama.cpp writes as a `--x, --no-x` pair; adding one from the
picker now gives you all three states. (Those flags were previously named after
their negation in the picker — `--no-jinja` rather than `--jinja` — so adding
one switched the setting off while the row read as switching it on.)

### Arguments are rows, not a string

There is no free-text argument field any more. The **Paste args** row is an
input: paste a command line into it and it splits into one row per parameter —
filling a built-in control where the flag has one, adding a parameter row where
it does not — and then empties itself.

```
-np 1 --reasoning-preserve   →   Slots (-np)      1
                                 Reasoning trace  on
```

The catalogue decides which tokens are values, so `-ngl -1` and
`--no-repack --parallel 2` split correctly where reading token shape would not.
Short aliases, negations and the `--flag=value` form all resolve to the same
parameter the picker would have added. A flag this build's `--help` does not
describe is kept as typed, with a note of whether it took a value, so a flag
from an alternate binary still reaches the server rather than being rendered
and silently dropped. Anything belonging to no flag at all stays in the field,
is named on the page, and is still passed verbatim.

An argument string in a settings file written before this splits itself on
load, so nothing has to be retyped.

## Hardware auto-tuning

The Tuning page prefills suggestions derived from an actual probe of the
machine (`hw_probe.sh` → GPU vendor, VRAM, RAM, physical cores):

- **GPU layers** — `-1` (llama.cpp's auto-fit) whenever there is usable VRAM,
  since llama.cpp knows per-layer sizes and this plugin does not. `0` when
  offloading would not pay for itself.
- **Threads** — physical cores, not hyperthreads, minus one on larger machines.
- **Context / batch** — scaled to the memory that will actually hold the KV
  cache.

They are suggestions: shown under the controls, applied only via **Apply
detected defaults**.

CUDA-specific workarounds (`GGML_CUDA_REGISTER_HOST`,
`GGML_CUDA_DISABLE_GRAPHS`) are applied only when an NVIDIA GPU is detected.

## ollama as a system service

A root-owned `ollama.service` cannot be stopped by this widget (that needs
privileges it does not have). It is detected, adopted and monitored, and the
Stop button is disabled with an explanatory note. Manage it with
`systemctl`. A server the widget started itself is fully controllable.

## Development

```bash
node --test tests/*.test.js
```

`slot_kv.py` is exercised end to end against
`tests/fixtures/fake_backend.py`, so the suite needs `python3`.

Pure logic lives in `Model.js` (parsing, tree/label helpers), `Backends.js`
(backend registry, URLs, launch/detach commands), `Hardware.js`
(probe → suggestions) and `Profiles.js` (the per-model tuning store), all
Node-testable with no QML dependency. `Panel.qml`
holds the UI and process orchestration.

Saving any file under `~/.config/omarchy/plugins/` triggers a plugin reload,
but a widget already on the bar is not always rebuilt by it — run
`omarchy restart shell` to be sure you are looking at the new code (a running
server survives it).

## Idées non implémentées

### Liens symboliques vers les blobs ollama

Les modèles ollama sont déjà exposés à llama.cpp en pointant directement sur le
blob (voir « Partage de modèles »). Une amélioration possible : créer des liens
symboliques lisibles — `~/models/shared/qwen3-8b.gguf` → le blob — pour que
LM Studio, jan ou n'importe quel outil acceptant un chemin GGUF les utilise
sans dupliquer les fichiers.

Limite connue à documenter au passage : ollama empaquette les GGUF de modèles
récents plus vite que llama.cpp ne les prend en charge. Mesuré sur ce système :

- `qwen3:8b` se charge sans problème depuis le blob ;
- `gemma4:e4b` échoue avec `wrong number of tensors; expected 2131, got 720`.

Ce n'est pas un défaut de la méthode — llama.cpp reconnaît les GGUF par leurs
octets magiques, pointer sur le blob est la technique recommandée. C'est un
décalage de version. Pour gemma4 en particulier, mieux vaut s'abstenir : les
Per-Layer Embeddings des variantes E2B/E4B ne sont pas implémentés dans le
graphe de calcul de llama.cpp (ggml-org/llama.cpp#22243), donc le modèle
tournerait avec une qualité dégradée sans rien signaler.
