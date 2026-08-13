# Installation

Detailed guide for macOS and Windows (WSL2). The short version lives in the
[README](../README.md).

At the end there is always the same self-test: **`veto-gate doctor`**. It is
the only authority that says, bindingly for your machine, whether the gate
can run — this guide describes the usual way there, it does not replace the
test.

> **Verification status:** The macOS path has been walked through on a real
> machine (bash 3.2, no GNU coreutils). The WSL path is plausibly described
> but has **not yet been verified end to end on a WSL machine** — where it
> breaks, please report it.

---

## What veto-gate needs

| Tool | For | Required? |
|---|---|---|
| `bash` 3.2+ | The hooks themselves | yes |
| `git` | Reading diff and index | yes |
| `python3` | Diff bundling, `veto-gate serve` | yes |
| `jq` | Reading JSON verdicts and config | yes |
| `perl` | Grounding check for invented method calls | yes |
| `codex` CLI | The main reviewer (your own account) | yes¹ |
| `timeout` | Time limiting, fast path | no² |
| LM Studio / Ollama | Free local pre-checker | no |

¹ Without `codex` the gate blocks **every** commit (fail-closed). That is
intentional: better to block than to wave things through unreviewed.

² If `timeout` is missing (the normal case on macOS), perl takes over the
time limiting. That is why perl is required and `timeout` is not.

> **perl is not an accessory.** Without perl, the check for invented method
> calls (`db.doesNotExist()`) stays silent. In that case the gate refuses to
> run and blocks with a clear message — it does not pretend to have reviewed.

---

## macOS

> **In a hurry?** `curl -fsSL https://raw.githubusercontent.com/revvax/veto-gate/main/boot.sh | bash`
> does steps 1–4 below, asking before it installs anything. The rest of this
> chapter is the same route by hand — useful when a step fails and you want to
> see where.

### 1. Xcode Command Line Tools

Provides `git`, `python3` and `perl`:

```bash
xcode-select --install
```

If it is already there, the command says so and does nothing.

### 2. `jq`

macOS 26 ships `jq` (`/usr/bin/jq`, verified: `jq-1.7.1-apple`). Test:

```bash
jq --version
```

If you get "command not found" (older macOS), install it via
[Homebrew](https://brew.sh):

```bash
brew install jq
```

### 3. Codex CLI + login

The CLI runs on Node, so Node first (`brew install node` if missing):

```bash
npm install -g @openai/codex
codex login
```

`codex login` opens the browser. You need your **own** OpenAI account —
veto-gate does not bring any access and does not pay for anything on your
behalf.

Verify:

```bash
codex --version
```

### 4. Install veto-gate

```bash
git clone https://github.com/revvax/veto-gate.git
cd veto-gate
./install.sh
```

The installer links the hooks into `~/.claude/hooks/…` (symlinks — a later
`git pull` in this folder updates them along) and adds one entry to
`~/.claude/settings.json`. **Leave the cloned folder in place**: the
symlinks point into it. Your own, foreign files are never overwritten.

### 5. Self-test

```bash
veto-gate doctor
```

On a healthy macOS it looks like this — `timeout` is missing here and that
is correct (the tool's output is currently German):

```
✓ git gefunden
✓ python3 gefunden
✓ jq gefunden
✓ perl gefunden
✓ bash 3.2 (Pflicht: >=3)
✓ codex-CLI gefunden
ⓘ timeout fehlt (normal auf macOS) — perl übernimmt die Zeitbegrenzung
→ Pflicht-Abhängigkeiten: alle da
```

If it says `veto-gate: command not found`, `~/.local/bin` does not exist on
your machine or is not on the `PATH`. Then call it directly:

```bash
bash ~/.claude/hooks/lib/veto-gate/veto-gate-cli.sh doctor
```

(The old command name `veto2` keeps working transitionally.)

---

## Windows

> **Untested:** This section has not yet been walked through end to end on
> a real WSL machine. The steps are written from documentation — if
> something is wrong, please report it as an issue.

**WSL2 only. It does not run natively** — and that cannot be fixed with a
switch: veto-gate is bash, perl and python tooling. Git Bash, PowerShell
and the command prompt are **not** viable paths. If you want the gate on
Windows, you work in WSL.

Important, because it is the most common source of errors: **Claude Code
must also run in WSL.** The gate hooks into the `~/.claude/settings.json`
**inside** WSL. A Claude Code running on the Windows side never sees this
hook and keeps committing unreviewed.

### 1. Set up WSL2

In PowerShell **as administrator**:

```powershell
wsl --install
```

Then reboot. This installs Ubuntu by default. Everything else happens
**in the Ubuntu window**, not in PowerShell.

### 2. Dependencies

```bash
sudo apt update
sudo apt install -y git python3 jq perl curl
```

`perl` is in this list on purpose. Ubuntu normally ships it, but slim
images (containers, minimal installs) do not — and without perl the gate
refuses to work instead of silently half-checking.

### 3. Codex CLI + login

Install Node in WSL (e.g. via
[nodesource](https://github.com/nodesource/distributions) or `nvm`), then:

```bash
npm install -g @openai/codex
codex login
```

If no browser opens, `codex login` prints a URL — open it in the Windows
browser.

### 4. Install veto-gate — in the WSL file system

```bash
cd ~
git clone https://github.com/revvax/veto-gate.git
cd veto-gate
./install.sh
```

Do **not** clone into `/mnt/c/...`. The installer works with symlinks and
execute permissions; both are unreliable on the mounted Windows drive. The
WSL path `~` (i.e. `/home/<name>`) is the right place.

### 5. Self-test

```bash
veto-gate doctor
```

In WSL, `timeout` is present (GNU coreutils), so you get
`✓ timeout gefunden (schneller Pfad für Zeitbegrenzung)` instead of the
macOS line. What matters is the last line:
`→ Pflicht-Abhängigkeiten: alle da`.

---

## Enabling the gate for a repo

veto-gate is **opt-in per repo** — after installation, nothing happens
anywhere at first. In every repo that should be reviewed:

```bash
cd your-project
veto-gate enable
```

This writes `.claude/config/veto-gate.json` at the repo root. An existing
config is merged into, not replaced — settings like `max_lines` or
`prechecker` survive. `veto-gate disable` turns it off again.

From then on, every `git commit` in this repo has its diff reviewed before
it goes through. All switches are listed in the
[README](../README.md#configuration-claudeconfigveto-gatejson).
(The old file name `veto2.json` is still read transitionally when no
`veto-gate.json` exists.)

---

## Optional: local pre-checker (LM Studio / Ollama)

A small local model looks at the diff before Codex and blocks the obvious
mistakes without burning Codex quota. Free, runs on your machine. The
default is **off**. **Any OpenAI-compatible endpoint** works — LM Studio
and Ollama are the two proven paths. `"prechecker": "qwen"` below is a
fixed config keyword, not a model requirement: you write it literally no
matter which model you actually point the URL/model variables at.

**macOS, LM Studio:** install [LM Studio](https://lmstudio.ai), load a
model, start the local server (default port `1234`). Then in the repo:

```json
{ "enabled": true, "prechecker": "qwen" }
```

By default the pre-checker expects the model `qwen3.6-35b-a3b-mlx` at
`http://127.0.0.1:1234`. If your model is named differently, the name must
match **exactly** — veto-gate only sends the diff to a server that lists
precisely this model under `/v1/models` (the diff may contain sensitive
code). If it does not match, the pre-checker silently drops out and Codex
takes over. Different name/server:

```bash
export VETO_GATE_QWEN_MODEL="<your-model>"
export VETO_GATE_QWEN_URL="http://127.0.0.1:1234/v1/chat/completions"
```

**Ollama:** same mechanism, different port, model ID from `ollama list`:

```bash
export VETO_GATE_QWEN_URL="http://127.0.0.1:11434/v1/chat/completions"
export VETO_GATE_QWEN_MODEL="<model-from-ollama-list>"
```

**WSL:** Two pitfalls. First, `qwen3.6-35b-a3b-mlx` is an MLX model — MLX
only exists on Apple Silicon. On Windows/WSL your model is guaranteed to be
named differently, so `VETO_GATE_QWEN_MODEL` is mandatory. Second, LM
Studio runs on the Windows side but your gate runs in WSL: `127.0.0.1`
then points nowhere. Enable "Serve on Local Network" in LM Studio and check
reachability before switching the pre-checker on:

```bash
curl -s http://<windows-host-ip>:1234/v1/models | jq '.data[].id'
```

If that lists your model ID, set both:

```bash
export VETO_GATE_QWEN_URL="http://<windows-host-ip>:1234/v1/chat/completions"
export VETO_GATE_QWEN_MODEL="<the-id-from-above>"
```

If there is no answer, leave the pre-checker off (`"prechecker": "none"`) —
it is pure cost saving, not part of the review chain. Codex remains the
final reviewer in both cases.

---

## Optional: remote pre-checker (Groq / Gemini)

Like the local pre-checker, but via a free API provider instead of your
own machine — and unlike the local slot, this one is **not** open to any
provider: Groq and Gemini are the only two options the code currently
understands (`veto-gate key` only accepts `groq` or `gemini`). Store the
key once (input is hidden; the file ends up with `600` permissions under
`~/.claude/veto-gate/keys/`, outside of any repo):

```bash
veto-gate key groq      # or: veto-gate key gemini
```

Then set `"prechecker": "groq"` or `"prechecker": "gemini"` in the repo.
A different model than the default:

```bash
export VETO_GATE_GROQ_MODEL="<groq-model>"      # default: llama-3.3-70b-versatile
export VETO_GATE_GEMINI_MODEL="<gemini-model>"  # default: gemini-3.5-flash
```

**Use free-tier keys only.** Gemini: create the project **without**
billing — with billing the free tier disappears and every gate run costs
money. veto-gate cannot technically enforce this; the responsibility hangs
on the key.

---

## Optional: block notifications to your phone (Discord)

When the gate blocks a commit, it can additionally send the reasoning to a
Discord channel (three fields: WHAT / WHY / HOW IT GETS RESOLVED). Without
setup, simply nothing happens — the notification is a silent extra, never
part of the review chain.

1. In Discord: channel → settings → integrations → create a webhook, copy
   the URL.
2. Set the URL as an environment variable (e.g. in `~/.zshrc` /
   `~/.bashrc`):

```bash
export DISCORD_VETO_WEBHOOK="https://discord.com/api/webhooks/YOUR-ID/YOUR-TOKEN"
```

The URL is a secret: whoever has it can write into your channel. Never
commit it into the repo — that is why `secret-scan.sh` raises an alarm on
webhook URLs in code. Test run without actually sending:
`VETO_GATE_DISCORD_DRY_RUN=1` only prints what would be sent.

---

## When something is stuck

| Symptom | Cause | Way out |
|---|---|---|
| Every commit gets blocked | `codex` missing or not logged in | `codex login`, then `veto-gate doctor` |
| "Grounding-Prüfung konnte nicht laufen — perl fehlt" (grounding check could not run — perl missing) | perl not installed | macOS: `xcode-select --install` · WSL: `sudo apt install perl` |
| `veto-gate: command not found` | `~/.local/bin` missing or not on `PATH` | `bash ~/.claude/hooks/lib/veto-gate/veto-gate-cli.sh doctor` |
| Gate does nothing in a repo | Repo not enabled | `veto-gate enable` in the repo |
| Nothing happens on Windows | Claude Code runs on the Windows side | start Claude Code in WSL |
| Hooks broken after moving the folder | Symlinks point at the old clone | in the clone `./uninstall.sh`, move it, `./install.sh` |

## Uninstall

```bash
./uninstall.sh
```

Removes exactly the symlinks and the one `settings.json` entry that
`install.sh` created. The backups of `settings.json` are left in place.
