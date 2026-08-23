# OpenCode GB10 installer integration

## Locked decisions (user-confirmed; do not revisit)

- 2026-08-23: "update this installer to install opencode and it's configuration with my gb10"
- 2026-08-23: "continue"
- The installer must install OpenCode and configure the installed user's default model to use the user's GB10.
- The installer must add the recommended GB10 model metadata, bounded timeout, and portable global OpenCode agent rules.

## Verified facts

- `C:\dev\ubuntu-auto-installer-scripts\scripts\install-optional-features.sh` installs development tools and AI command-line tools during first boot.
- `C:\dev\ubuntu-auto-installer-scripts\.env.sample` enables development tools by default and is the documented source for USB settings.
- `C:\dev\ubuntu-auto-installer-scripts\create-usb.bat` writes optional-feature values to `/opt/ubuntu-installer/config.env` through the USB copy.
- `C:\dev\ubuntu-auto-installer-scripts\cmd\usb-creator\main.go` has a separate configuration generator that must stay consistent with the batch creator.
- `C:\Users\Jeremy\.config\opencode\opencode.json.bak.dg10.1787479104` identifies the user's GB10-compatible Ollama endpoint as `http://192.168.40.250:11434/v1` and model family as `qwen-coder-yarn`.
- A live `GET http://192.168.40.250:11434/v1/models` returned HTTP 200 on 2026-08-23 and listed the exact current model ID `qwen-coder-yarn:latest`.
- A live `POST http://192.168.40.250:11434/api/show` returned `tools,completion`, context length `524288`, and configured `num_ctx 524288` for `qwen-coder-yarn:latest`.
- The current OpenCode schema at `https://opencode.ai/config.json` supports provider `timeout` and model `tool_call`, `reasoning`, `attachment`, `limit`, and `modalities` fields.
- `C:\Users\Jeremy\.config\opencode\AGENTS.md` contains no detected credential patterns, but its 150 lines include branch-specific cloud and operator-email rules that do not belong in every GB10 prompt.
- The current OpenCode 1 documentation specifies `npm install -g opencode-ai`, global configuration at `~/.config/opencode/opencode.json`, and `@ai-sdk/openai-compatible` for OpenAI-compatible endpoints.
- `git status --short --branch` returned `## main...origin/main` plus untracked `agents.md` and `claude.md`. Those unrelated files will not be staged.

## Workstreams

### Workstream A: Installer behavior

[x] Add an idempotent OpenCode install and GB10 configuration function to `C:\dev\ubuntu-auto-installer-scripts\scripts\install-optional-features.sh`.

Definition of done: `bash -n scripts/install-optional-features.sh` exits 0 and focused tests verify the install command, endpoint, model, ownership, and invocation.

### Workstream B: Configuration propagation

[x] Add documented OpenCode settings to `C:\dev\ubuntu-auto-installer-scripts\.env.sample`, `C:\dev\ubuntu-auto-installer-scripts\create-usb.bat`, and `C:\dev\ubuntu-auto-installer-scripts\cmd\usb-creator\main.go`.

Dependency: Workstream A variable names are final.

Definition of done: `go test ./...` exits 0 and focused tests confirm that both USB creation paths emit all OpenCode settings.

### Workstream C: Documentation and delivery

[x] Document the enabled default, GB10 endpoint, model, installed path, and override controls in `C:\dev\ubuntu-auto-installer-scripts\README.md`.

Dependency: Workstreams A and B are complete.

Definition of done: all focused verification commands exit 0, task files are committed, `git push origin main` exits 0, and the resulting GitHub workflow reaches a terminal success result or the repository has no workflow.

### Workstream D: GB10 model metadata

[~] Add configurable context, output, and timeout values plus verified tool and modality metadata to the generated OpenCode model.

Definition of done: `node --test scripts/configure-opencode.test.js` exits 0 and asserts the exact provider and model metadata.

### Workstream E: Portable global agent rules

[ ] Install a compact `~/.config/opencode/AGENTS.md` that preserves the existing file in a one-time backup and omits machine-specific credentials, cloud identifiers, and unrelated branch rules.

Dependency: Workstream D helper interface is final.

Definition of done: focused tests verify new install, existing-file backup, idempotent replacement, USB propagation, and target ownership logic.

### Workstream F: Second delivery

[ ] Update documentation, run all repository checks, commit only task files, push `main`, and inspect the resulting GitHub workflow state.

Dependency: Workstreams D and E are complete.

Definition of done: `bash -n scripts/install-optional-features.sh`, `node --test scripts/configure-opencode.test.js`, `go test ./...`, and `go vet ./...` exit 0; the remote `main` ref matches local `HEAD`.

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
- 2026-08-23: Added the OpenCode install, merge helper, GB10 settings, both USB propagation paths, tests, and documentation.
- 2026-08-23: `bash -n scripts/install-optional-features.sh` exited 0.
- 2026-08-23: `node --test scripts/configure-opencode.test.js` returned 3 passing tests and 0 failures.
- 2026-08-23: `go test ./...` returned `ok ubuntu-auto-installer/cmd/usb-creator`.
- 2026-08-23: A live GB10 `/v1/models` query returned HTTP 200 and confirmed `qwen-coder-yarn:latest`.
- 2026-08-23: Commit `4847460` recorded the installer implementation and focused tests.
- 2026-08-23: `git push origin main` advanced the remote from `83f3a71` to `4847460`.
- 2026-08-23: `.github/workflows` does not exist and `gh run list --commit 4847460` returned `[]`; this repository has no workflow to monitor.
- 2026-08-23: Read the complete `writing-for-agents` skill and the existing global OpenCode `AGENTS.md`; selected a compact always-loaded rule set to reduce context load.
