# OpenCode GB10 installer integration

## Locked decisions (user-confirmed; do not revisit)

- 2026-08-23: "update this installer to install opencode and it's configuration with my gb10"
- The installer must install OpenCode and configure the installed user's default model to use the user's GB10.

## Verified facts

- `C:\dev\ubuntu-auto-installer-scripts\scripts\install-optional-features.sh` installs development tools and AI command-line tools during first boot.
- `C:\dev\ubuntu-auto-installer-scripts\.env.sample` enables development tools by default and is the documented source for USB settings.
- `C:\dev\ubuntu-auto-installer-scripts\create-usb.bat` writes optional-feature values to `/opt/ubuntu-installer/config.env` through the USB copy.
- `C:\dev\ubuntu-auto-installer-scripts\cmd\usb-creator\main.go` has a separate configuration generator that must stay consistent with the batch creator.
- `C:\Users\Jeremy\.config\opencode\opencode.json.bak.dg10.1787479104` identifies the user's GB10-compatible Ollama endpoint as `http://192.168.40.250:11434/v1` and model as `qwen-coder-yarn`.
- The current OpenCode 1 documentation specifies `npm install -g opencode-ai`, global configuration at `~/.config/opencode/opencode.json`, and `@ai-sdk/openai-compatible` for OpenAI-compatible endpoints.
- `git status --short --branch` returned `## main...origin/main` plus untracked `agents.md` and `claude.md`. Those unrelated files will not be staged.

## Workstreams

### Workstream A: Installer behavior

[~] Add an idempotent OpenCode install and GB10 configuration function to `C:\dev\ubuntu-auto-installer-scripts\scripts\install-optional-features.sh`.

Definition of done: `bash -n scripts/install-optional-features.sh` exits 0 and focused tests verify the install command, endpoint, model, ownership, and invocation.

### Workstream B: Configuration propagation

[ ] Add documented OpenCode settings to `C:\dev\ubuntu-auto-installer-scripts\.env.sample`, `C:\dev\ubuntu-auto-installer-scripts\create-usb.bat`, and `C:\dev\ubuntu-auto-installer-scripts\cmd\usb-creator\main.go`.

Dependency: Workstream A variable names are final.

Definition of done: `go test ./...` exits 0 and focused tests confirm that both USB creation paths emit all OpenCode settings.

### Workstream C: Documentation and delivery

[ ] Document the enabled default, GB10 endpoint, model, installed path, and override controls in `C:\dev\ubuntu-auto-installer-scripts\README.md`.

Dependency: Workstreams A and B are complete.

Definition of done: all focused verification commands exit 0, task files are committed, `git push origin main` exits 0, and the resulting GitHub workflow reaches a terminal success result or the repository has no workflow.

## Restart policy

- Local verification: classify the first failure. Fix deterministic code or test failures before one rerun. Allow at most two runs of the same verification command.
- Git push: retry one transient network failure after confirming the branch and remote. Do not retry authentication failures.
- GitHub workflow: monitor success and failure. Fix deterministic repository failures before one new push. Allow at most two delivery pushes for this task.

## Stop conditions (only these)

- Git credentials required for the mandatory push are unavailable.
- Completion requires an unrelated destructive data change.
- Completion requires a material scope expansion beyond installing and configuring OpenCode for the GB10 endpoint.

## Execution log

- 2026-08-23: `git status --short --branch` confirmed clean tracked files on `main`; untracked `agents.md` and `claude.md` are preserved.
- 2026-08-23: `rg` and focused file reads traced optional-feature installation and both USB configuration paths.
- 2026-08-23: Official OpenCode documentation confirmed the OpenCode 1 npm package, global configuration location, and compatible-provider schema.
