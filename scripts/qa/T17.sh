#!/usr/bin/env bash
# T17 manual QA fixture for a disposable macOS VM (never run on a real Mac that uses Docker).
#   scripts/qa/T17.sh setup | teardown | mode ok|down|hang|conflict
# Installs a shim `docker` at ~/.docker/bin/docker that replays state from ~/ADKQA-T17/state, a real unix socket at
# ~/.docker/run/docker.sock and a sparse Docker.raw. Refuses to run when those locations already exist without the marker.
set -euo pipefail
Q="$HOME/ADKQA-T17"; MARK=".adkqa-T17"
DOCKER_DIR="$HOME/.docker"; CONT="$HOME/Library/Containers/com.docker.docker"
case "${1:-}" in
setup)
  for d in "$DOCKER_DIR" "$CONT"; do
    if [[ -e "$d" && ! -e "$d/$MARK" ]]; then echo "refusing: $d exists without $MARK" >&2; exit 1; fi
  done
  mkdir -p "$Q/state" "$DOCKER_DIR/bin" "$DOCKER_DIR/run" "$CONT/Data/vms/0/data"
  touch "$DOCKER_DIR/$MARK" "$CONT/$MARK"; echo ok > "$Q/mode"
  A=$(printf 'a%.0s' {1..64}); E=$(printf 'e%.0s' {1..64})
  cat > "$Q/state/images" <<J
{"ID":"sha256:$A","Repository":"<none>","Tag":"<none>","CreatedAt":"2026-01-01 10:00:00 +0000 UTC"}
{"ID":"sha256:$(printf 'b%.0s' {1..64})","Repository":"adkqa/img","Tag":"1","CreatedAt":"2026-01-01 10:00:00 +0000 UTC"}
J
  echo "{\"ID\":\"$E\",\"Names\":\"adkqa-stopped\",\"Image\":\"alpine\",\"State\":\"exited\",\"Status\":\"Exited (0) 2 days ago\"}" > "$Q/state/containers"
  echo '{"Name":"adkqa-named","Labels":""}' > "$Q/state/volumes"
  cat > "$DOCKER_DIR/bin/docker" <<'S'
#!/bin/sh
Q="$HOME/ADKQA-T17"; echo "$@" >> "$Q/argv.log"; env | sort >> "$Q/env.log"
case "$(cat "$Q/mode")" in down) echo "Cannot connect to the Docker daemon" >&2; exit 1;; hang) sleep 300;; esac
case "$1 $2" in
  "version --format") echo '{"Client":{"Version":"27"},"Server":{"Version":"27.0.1"}}';;
  "image ls") cat "$Q/state/images";;
  "container ls") [ "$3" = "--all" ] && [ "$4" = "--no-trunc" ] && cat "$Q/state/containers";;
  "volume ls") cat "$Q/state/volumes";;
  "system df") echo '{"Images":[],"Containers":[],"Volumes":[],"BuildCache":[{"ID":"x","InUse":"false","Size":"5MB"}]}';;
  "image rm"|"container rm"|"volume rm"|"builder prune")
    [ "$(cat "$Q/mode")" = conflict ] && { echo "conflict: unable to delete" >&2; exit 1; }
    echo removed;;
  *) exit 0;;
esac
S
  chmod 755 "$DOCKER_DIR/bin/docker" "$DOCKER_DIR/bin" "$DOCKER_DIR"
  python3 -I -c "import socket,os;p=os.path.expanduser('~/.docker/run/docker.sock');s=socket.socket(socket.AF_UNIX);s.bind(p);import time;time.sleep(86400)" &
  echo $! > "$Q/sock.pid"
  mkfile -n 8g "$CONT/Data/vms/0/data/Docker.raw"; dd if=/dev/urandom of="$CONT/Data/vms/0/data/Docker.raw" bs=1m count=200 conv=notrunc 2>/dev/null
  echo "ready. Note: the df state above lists only build cache; edit $Q/state or the shim for richer data."
  ;;
mode) echo "${2:?ok|down|hang|conflict}" > "$Q/mode";;
teardown)
  [[ -f "$Q/sock.pid" ]] && kill "$(cat "$Q/sock.pid")" 2>/dev/null || true
  for d in "$DOCKER_DIR" "$CONT"; do [[ -e "$d/$MARK" ]] && rm -rf "$d"; done
  rm -rf "$Q";;
*) sed -n '2,5p' "$0"; exit 2;;
esac
