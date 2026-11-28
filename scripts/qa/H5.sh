#!/bin/bash
# H5 QA fixtures (process control). Run in the Tart VM only, never on the owner's Mac.
# Everything lives under ~/ADKQA-H5. The fixtures must NOT be system binaries: pause and background are refused for
# anything under /bin, /usr, /sbin or /System, so `start` compiles a tiny writer into ~/ADKQA-H5/bin (needs `cc`, i.e.
# the Xcode command line tools already in adk-base) and runs that. It forks one child (the same binary, exec'd) so
# there is a tree and a way to check background inheritance.
# stop/teardown signal ONLY the two pids this script recorded (never by name or pattern).
#   start     adk-writer parent + child; pids in ~/ADKQA-H5/{parent,child}.pid
#   status    ps state of the two recorded pids
#   stop      SIGCONT then SIGTERM to the two recorded pids (fixtures only), remove the pid files
#   teardown  stop + remove ~/ADKQA-H5
set -euo pipefail

ROOT="$HOME/ADKQA-H5"
BIN="$ROOT/bin/adk-writer"
guard() { [ "$(sysctl -n kern.hv_vmm_present 2>/dev/null)" = "1" ] || { echo "refusing to run outside a VM" >&2; exit 1; }; }

build() {
  mkdir -p "$ROOT/bin"
  cat > "$ROOT/bin/adk-writer.c" <<'C'
// adk-writer parent <dir>: forks+execs itself as "child", then both write 64 MB, fsync, rewind, forever.
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>
static void write_loop(const char *path) {
  static char buf[1 << 20];
  memset(buf, '0', sizeof buf);
  int fd = open(path, O_WRONLY | O_CREAT, 0644);
  if (fd < 0) _exit(1);
  for (;;) {
    lseek(fd, 0, SEEK_SET);
    for (int i = 0; i < 64; i++) if (write(fd, buf, sizeof buf) < 0) _exit(1);
    fsync(fd);
  }
}
int main(int argc, char **argv) {
  if (argc < 3) return 2;
  char path[1024];
  if (strcmp(argv[1], "child") == 0) { snprintf(path, sizeof path, "%s/child.dat", argv[2]); write_loop(path); }
  pid_t kid = fork();
  if (kid == 0) { execl(argv[0], argv[0], "child", argv[2], (char *)NULL); _exit(127); }
  snprintf(path, sizeof path, "%s/child.pid", argv[2]);
  FILE *f = fopen(path, "w"); if (f) { fprintf(f, "%d\n", kid); fclose(f); }
  snprintf(path, sizeof path, "%s/parent.dat", argv[2]);
  write_loop(path);
}
C
  cc -O1 -o "$BIN" "$ROOT/bin/adk-writer.c"
}

case "${1:-}" in
  start)
    guard
    mkdir -p "$ROOT"
    [ -x "$BIN" ] || build
    cd "$ROOT"
    nohup "$BIN" parent "$ROOT" >/dev/null 2>&1 &
    echo $! > "$ROOT/parent.pid"
    sleep 1
    echo "fixture started: parent $(cat "$ROOT/parent.pid"), child $(cat "$ROOT/child.pid" 2>/dev/null || echo '?') (binary under $ROOT/bin, not a system path)."
    echo "Steps: Disk activity -> adk-writer rows. Background (tree): note the write rate before/after. Pause: ps stat = T, 0 MB/s."
    echo "Auto-resume (set 1 min). Pause then quit the app -> running again. Pause then 'kill -9' the app PID -> relaunch -> recovery sheet."
    echo "Finder -> refused with the message. Background inheritance: new child of a backgrounded parent: use 'status'."
    ;;
  status)
    for f in parent child; do
      [ -f "$ROOT/$f.pid" ] && ps -o pid,ppid,stat,nice,command -p "$(cat "$ROOT/$f.pid")" || echo "$f: not recorded"
    done
    ;;
  stop)
    for f in child parent; do
      if [ -f "$ROOT/$f.pid" ]; then
        p=$(cat "$ROOT/$f.pid")
        kill -CONT "$p" 2>/dev/null || true   # fixtures only: a stopped process can't act on SIGTERM
        kill "$p" 2>/dev/null || true
        rm -f "$ROOT/$f.pid"
      fi
    done
    ;;
  teardown)
    guard
    "$0" stop
    rm -rf "$ROOT"
    ;;
  *) echo "usage: $0 start|status|stop|teardown" >&2; exit 2 ;;
esac
