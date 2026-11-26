# Docker scanner and cleanup (T17)

`DockerScanner` (id `docker`, virtual namespace `docker`) lists what Docker could free and `DockerToolCommands` removes it.
Items are **virtual** (`/.aidiskkeeper-virtual/docker/<runtime>/<kind>/<id>`): there is no file behind them, so they are cleaned by
the runtime's own CLI through the shell-free, allowlisted tool-command runner (PLAN §7 invariant 19), never by the Trash.

## Runtimes (`DockerRuntimeLayout`)

| Runtime (id) | CLI candidates (absolute; first safe wins) | Socket | VM disk image (`lstat` only) |
|---|---|---|---|
| Docker Desktop (`docker-desktop`) | `~/.docker/bin/docker`, `/usr/local/bin/docker`, `/Applications/Docker.app/Contents/Resources/bin/docker` | `~/.docker/run/docker.sock` | `~/Library/Containers/com.docker.docker/Data/vms/*/data/Docker.raw` |
| OrbStack (`orbstack`) | `~/.orbstack/bin/docker`, `/Applications/OrbStack.app/Contents/MacOS/xbin/docker`, `/usr/local/bin/docker` | `~/.orbstack/run/docker.sock` | `~/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data/data.img` |
| Colima (`colima-<profile>`) | `/opt/homebrew/bin/docker`, `/usr/local/bin/docker` | `~/.colima/<profile>/docker.sock` | `~/.colima/_lima/_disks/<profile>/datadisk`, else `~/.colima/_lima/colima[-<profile>]/diffdisk` |

These paths come from the runtimes' documented layouts and have **not** been confirmed on a real machine yet (see QA below).
The socket must be a socket owned by the user; a symlink is followed once and must stay under `~`. The CLI always runs with
`DOCKER_HOST=unix://<socket>`, so the user's current context and `~/.docker/config.json` play no part and nothing goes over the
network. `/var/run/docker.sock`, TCP, SSH and remote contexts are never used. A missing socket launches **no process**; the app
never starts or stops a runtime. Rancher Desktop is not included yet.

## Commands

Read-only probes (not audited): `version`, `system df -v`, `image ls`, `container ls --all`, `volume ls` (scan), and per-object
`image inspect`, `container ls --filter ancestor=…|volume=…`, `container inspect`, `volume inspect` (re-validation).

Destructive (bound to the item, re-validated at plan time and again right before running, audited with argv, exit status and duration):

| spec | rules | argv after `docker` |
|---|---|---|
| `docker.image.rm` | `tool.docker.image.dangling`, `tool.docker.image.unused` | `image rm <imageID>` or `image rm <ref>…` (1–8 tags) |
| `docker.container.rm` | `tool.docker.container.stopped` | `container rm <containerID>` |
| `docker.volume.rm` | `tool.docker.volume.anonymous` | `volume rm <name>` |
| `docker.builder.prune` | `tool.docker.buildcache` | `builder prune --all --force` |

Never: `system|image|container|volume|network prune`, `-f`/`--force` on any `rm`, `-v` on `container rm`, `compose`, `run`, `exec`,
`start`, `stop`, `kill`, `context`, `login`. `--force` on `builder prune` only skips the y/N prompt, which would read `/dev/null`.

## Tiers

Dangling image (Repository and Tag both `<none>`) ≥ 1 h old and unused build cache: **Safe**. Younger dangling image, tagged unused image, digest-only image (containerd: Tag `<none>` but named `repo@sha256:…`; removed by ID), stopped container,
unused anonymous or devcontainer-labelled volume: **Review**. Unused named volume: **Keep** (report only). Running, paused or
restarting containers, and anything in use, are never items. Volumes, containers and tagged images are never Safe.
Sizes are rounded by docker (3–4 digits) and shared layers may free less than shown: the result says "up to".

## The disk image

Docker keeps everything in one VM disk image. Removing objects frees space inside it right away; the file on the Mac shrinks only
when the runtime gives the space back. AI Disk Keeper never opens, edits, compacts, trashes or deletes it: the Models & Docker card
only shows its allocated and maximum size.

## Fixtures

Tests use a scripted fake runner and temp-dir layouts with real unix sockets (`Tests/DiskKeeperCoreTests/Scanners/Docker`).
Verified against real Docker Desktop 4.99 (engine 29.9.3, containerd snapshotter): `system df -v --format '{{json .}}'` is one
object (`Images`, `Containers`, `Volumes`, `BuildCache`) whose values are all strings (`"Containers":"0"`, `"InUse":"false"`,
`"1.753GB"`); dates look like `2026-11-26 20:55:29 +0700 +07`. On containerd, `image inspect` `RepoTags` also lists digest
references (`repo@sha256:…`); revalidation ignores those. Volumes, OrbStack and Colima output is still synthesized from
docker's documented formats; re-record sanitized output when one is available.
Tests never run the host's docker or use `DockerRuntimeLayout.live`.
