# k16-gh-agent-runner

Self-hosted GitHub Actions runner image with a pre-installed AI/CI toolchain and an optional local Actions cache server.

[![GHCR package](https://img.shields.io/badge/GHCR-ghcr.io%2Fkostua16%2Fk16--gh--agent--runner-blue)](https://ghcr.io/kostua16/k16-gh-agent-runner)
[![branch](https://img.shields.io/badge/branch-main-green)](https://github.com/kostua16/k16-gh-agent-runner/tree/main)

## Table of contents

- [What it does](#what-it-does)
- [What's in the image](#whats-in-the-image)
- [Prerequisites](#prerequisites)
- [Install](#install)
- [Managing the stack](#managing-the-stack)
- [Configuration](#configuration)
- [Build](#build)
- [Project layout](#project-layout)
- [Security](#security)

## What it does

This project provides a **Docker image** based on [falcondev-oss/actions-runner](https://github.com/falcondev-oss/actions-runner) that registers and runs as a **GitHub Actions self-hosted runner** via [`runner.sh`](runner.sh).

The image ships a **curated toolchain** (Node, Bun, `gh`, AI agent CLIs, linters, Docker CLI, and more) so workflows spend less time installing tools on every job.

Production deployment is a **two-service** Compose stack ([`docker-compose.yml`](docker-compose.yml)):

| Service | Role |
|---------|------|
| **runner** | Self-hosted runner (needs `GITHUB_URL` + `RUNNER_TOKEN`) |
| **cache-server** | [falcondev Actions cache server](https://github.com/falcondev-oss/github-actions-cache-server) for faster caching on the internal Docker network |

The runner mounts **`/var/run/docker.sock`** so workflows can run Docker-based jobs. Your host user should be in the `docker` group (or equivalent).

The cache server is **not published on the host** (no port 3000 bind). Only the `runner` service reaches it at `http://cache-server:3000/`.

```mermaid
flowchart TB
  subgraph host [Host machine]
    compose[docker compose]
    sock[docker.sock]
  end
  subgraph stack [Compose stack]
    runner[runner container]
    cache["cache-server internal :3000"]
  end
  gh[GitHub Actions] <-->|jobs| runner
  runner -->|CUSTOM_ACTIONS_RESULTS_URL| cache
  runner --> sock
  compose --> runner
  compose --> cache
```

## What's in the image

Versions are pinned in [`env.build`](env.build) and installed by [`scripts/install-toolchain.sh`](scripts/install-toolchain.sh).

| Category | Tools (defaults) |
|----------|------------------|
| Base | GitHub Actions runner (falcondev-oss) |
| Runtime | Node.js 22, Bun 1.3.14, Python 3, **uv** |
| Package managers | npm, bun, **corepack** (pnpm / yarn) |
| CLI / quality | GitHub CLI 2.93.0, actionlint 1.7.7, **shellcheck**, **shfmt**, **make**, **yq**, git, jq, ripgrep, **openssh-client** |
| Containers | Docker CLI 28.x + Compose v2 plugin (installed if missing from base) |
| Archives | unzip, **xz-utils**, **zstd** |
| Security / lint | **hadolint**, **gitleaks** |
| AI agents (optional `INSTALL_*` build args) | GSD, RTK, OpenAI Codex CLI, Claude Code, Cursor Agent CLI |
| Data | Prisma CLI |

API keys (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `CURSOR_API_KEY`, etc.) are **not** baked into the image. Set them in GitHub Actions secrets or optional entries in `.env` for local testing.

To build a slimmer image, set `INSTALL_*=false` in `env.build` before `make build`.

## Prerequisites

- Linux host (**amd64** or **arm64**) with Docker Engine and **Compose v2** (`docker compose`)
- Writable access to `/var/run/docker.sock` on the host
- A GitHub **runner registration token** ([Adding self-hosted runners](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/adding-self-hosted-runners))

## Install

End users do **not** need a git clone. Download and run the installer from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/kostua16/k16-gh-agent-runner/main/install.sh | bash
```

Pass options after `bash -s --` (same script, no local checkout):

```bash
curl -fsSL https://raw.githubusercontent.com/kostua16/k16-gh-agent-runner/main/install.sh | bash -s -- --help
curl -fsSL https://raw.githubusercontent.com/kostua16/k16-gh-agent-runner/main/install.sh | bash -s -- --token "$RUNNER_TOKEN"
```

This will:

1. Create `~/k16-gh-agent-runner`
2. Download `docker-compose.yml`, `.env.example`, and `manage.sh` from the `main` branch
3. Run an interactive wizard to create `.env` (`RUNNER_TOKEN` is hidden input)
4. Start the stack with `./manage.sh up` in that directory

If `.env` already exists, you can **keep**, **overwrite**, or **edit** selected keys.

### Migrate from an existing self-hosted runner

If you already have a classic [`actions-runner`](https://github.com/actions/runner) install (for example `~/actions-runner` with `svc.sh` and `.runner`):

```bash
curl -fsSL https://raw.githubusercontent.com/kostua16/k16-gh-agent-runner/main/install.sh | bash -s -- --migrate
# or with a custom legacy path and token:
curl -fsSL https://raw.githubusercontent.com/kostua16/k16-gh-agent-runner/main/install.sh | bash -s -- --migrate ~/actions-runner --token "$RUNNER_TOKEN"
```

This will:

1. Verify the legacy directory (`.runner`, `svc.sh`)
2. Stop the legacy service when active (uses `sudo -n` only — no password prompts; skips stop when already inactive)
3. Import `GITHUB_URL` and `RUNNER_NAME` from `.runner`
4. Obtain a new `RUNNER_TOKEN` via `gh api` when available; otherwise use `--token`, legacy `.env`, or prompt
5. Set `RUNNER_LABELS` from GitHub when possible, otherwise auto-default to `self-hosted,<OS>,<ARCH>,docker`
6. Write `~/k16-gh-agent-runner/.env` and start the Docker stack

Requires **jq** for `--migrate`. **gh** is strongly recommended (`gh auth login`) so the script can fetch a fresh registration token and runner labels. Without `gh`, pass `--token` or export `RUNNER_TOKEN` (legacy `.env` tokens are often empty or expired).

When the legacy runner used systemd, migrate **stops** the unit but leaves it **enabled** — it may start again on reboot until you uninstall it manually. Migrate does not prompt for `sudo` passwords; if the unit is already inactive, no stop is attempted.

After start, the installer checks whether the runner container stays running and warns if it is restarting or exited.

Operator scripts (`install.sh`, `manage.sh`) run on **macOS default bash 3.2** (`/bin/bash`).

## Managing the stack

```bash
cd ~/k16-gh-agent-runner   # or your repo clone
./manage.sh                # interactive menu
./manage.sh up             # start
./manage.sh down           # stop
./manage.sh logs runner    # follow runner logs
./manage.sh ps             # status
./manage.sh restart
./manage.sh pull           # pull latest images
```

| Command | Description |
|---------|-------------|
| `up` | Start services (requires `.env`) |
| `down` | Stop and remove containers |
| `logs [service]` | Follow logs (`runner`, `cache-server`) |
| `ps`, `status` | Container status |
| `restart [service]` | Restart |
| `pull` | Pull images |

From a clone, `make up`, `make down`, and `make logs` delegate to `manage.sh`.

## Configuration

Copy [`.env.example`](.env.example) to `.env` or run the [install curl command](#install).

| Variable | Description |
|----------|-------------|
| `RUNNER_IMAGE` | Runner image (default `ghcr.io/kostua16/k16-gh-agent-runner:latest`) |
| `GITHUB_URL` | Repository or org URL for the runner |
| `RUNNER_TOKEN` | Registration token (required, short-lived) |
| `RUNNER_NAME` | Runner name on GitHub |
| `RUNNER_LABELS` | Comma-separated labels (default includes `docker`) |
| `RUNNER_DISABLE_UPDATE` | `true` to disable runner self-update |
| `RUNNER_EPHEMERAL` | `true` for ephemeral runners |

Optional workflow API keys can be added during install or appended to `.env` manually.

## Build

For maintainers building the image from source:

```bash
git clone https://github.com/kostua16/k16-gh-agent-runner.git
cd k16-gh-agent-runner
make build
```

From a clone you can also run `./install.sh` locally (same behavior as the curl one-liner).

- Uses [`env.build`](env.build) for version pins and [`docker-compose.build.yml`](docker-compose.build.yml) for the build overlay.
- Override versions via environment variables or by editing `env.build`.

Lint shell scripts (requires [shellcheck](https://www.shellcheck.net/)):

```bash
make lint
```

Push to GHCR (requires `gh auth login`):

```bash
make push
```

Run the stack from a clone:

```bash
cp .env.example .env   # edit secrets
make up
```

CI publishes the image on push to `main` and version tags via [`.github/workflows/docker-publish.yml`](.github/workflows/docker-publish.yml) to `ghcr.io/kostua16/k16-gh-agent-runner`.

## Project layout

| Path | Purpose |
|------|---------|
| `Dockerfile` | Runner image definition |
| `runner.sh` | Runner entrypoint (register + run) |
| `scripts/install-toolchain.sh` | Toolchain installer |
| `docker-compose.yml` | Production stack |
| `docker-compose.build.yml` | Build overlay only |
| `install.sh` | Bootstrap installer for end users |
| `manage.sh` | Compose management CLI + menu |
| `Makefile` | `build`, `push`, `up`, `down`, `logs` |
| `env.build` | Committed build-time versions (no secrets) |

## Security

- Never commit `.env` or runner registration tokens.
- Rotate `RUNNER_TOKEN` if leaked; tokens are short-lived at registration time.
- Mounting `docker.sock` grants container workflows effectively **root on the host** — only run trusted workflows and restrict runner access to your repos/orgs.
