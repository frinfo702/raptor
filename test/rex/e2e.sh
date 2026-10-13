#!/bin/sh
# End-to-end check of the rap server and CLI against a private socket.
#
# Usage: test/rex/e2e.sh [path/to/rap]   (default: zig-out/bin/rap)
set -eu

RAP=${1:-zig-out/bin/rap}
case $RAP in /*) ;; *) RAP=$PWD/$RAP ;; esac
[ -x "$RAP" ] || { echo "e2e: no rap binary at $RAP" >&2; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/rap-e2e.XXXXXX")
export RAP_SERVER="$tmp/s.sock"
# Keep the server log out of the real home.
export HOME="$tmp"
unset XDG_STATE_HOME RAP_SESSION RAP_BLOCK RAP_AUTOSTART

# A socket directly in /tmp, which other users can write to.
shared_sock=/tmp/rap-e2e-$$.sock

cleanup() {
  "$RAP" server stop >/dev/null 2>&1 || true
  "$RAP" -S "$shared_sock" server stop >/dev/null 2>&1 || true
  rm -rf "$tmp" "$shared_sock" "$shared_sock.lock"
}
trap cleanup EXIT

fail() {
  echo "e2e: FAIL: $*" >&2
  [ -f "$tmp/Library/Logs/Raptor/server.log" ] && cat "$tmp/Library/Logs/Raptor/server.log" >&2
  [ -f "$tmp/.local/state/raptor/server.log" ] && cat "$tmp/.local/state/raptor/server.log" >&2
  exit 1
}

# Expect exit status $1 from the rest of the command line.
expect_status() {
  want=$1
  shift
  set +e
  "$@" >"$tmp/out" 2>"$tmp/err"
  got=$?
  set -e
  [ "$got" -eq "$want" ] || fail "'$*' exited $got, want $want: $(cat "$tmp/err")"
}

# Retry a capture until it contains $2.
wait_capture() {
  i=0
  until "$RAP" capture -s "$1" | grep -q "$2"; do
    i=$((i + 1))
    [ $i -lt 100 ] || fail "capture of $1 never showed '$2'"
    sleep 0.05
  done
}

# Sessions persist after the CLI exits; send and capture reach the block.
# FOO is in the environment of the client that starts the server.
env FOO=bar "$RAP" new demo -- /bin/sh >/dev/null || fail "rap new demo"
"$RAP" send -s demo 'echo hi\n'
wait_capture demo hi
"$RAP" ls | grep -Eq "^demo +1 +1 +session:" || fail "rap ls does not list demo with 1 window and 1 block"

# Another client's session never sees FOO.
"$RAP" new other -- /bin/sh >/dev/null
"$RAP" send -s other 'echo "foo=[$FOO] block=$RAP_BLOCK"\n'
wait_capture other 'block=block:'
"$RAP" capture -s other | grep -q 'foo=\[\]' || fail "FOO leaked into a later session"

# From inside a block of demo, a block id still reaches other sessions.
other_block=$("$RAP" run -s other -- /bin/sh -c 'sleep 30')
expect_status 0 env RAP_SESSION=demo "$RAP" capture -b "$other_block"
expect_status 0 env RAP_SESSION=demo "$RAP" block inspect "$other_block"
# With -w, the block is looked up in that window of RAP_SESSION, even
# though the newest session has a window 2 as well.
demo_block=$("$RAP" run -s demo -- /bin/sh -c 'sleep 30')
expect_status 0 env RAP_SESSION=demo "$RAP" capture -w 2 -b "$demo_block"
"$RAP" close -b "$demo_block"
"$RAP" kill other

# Only one server per socket.
expect_status 1 "$RAP" server run
grep -q "already running" "$tmp/err" || fail "second server did not say already running"

# An explicit socket path in a shared directory is allowed.
"$RAP" -S "$shared_sock" new shared -- /bin/sh >/dev/null || fail "server on $shared_sock"
"$RAP" -S "$shared_sock" ls | grep -q shared || fail "rap ls on $shared_sock"
"$RAP" -S "$shared_sock" server stop

# Missing targets exit 3.
expect_status 3 "$RAP" capture -s nope

# Splits, zoom, focus, and inspection.
block=$("$RAP" split -s demo --down -- /bin/sh -c 'echo split-ok; sleep 30')
# A bare block position counts in the newest session, not across all.
"$RAP" new pos -- /bin/sh >/dev/null
expect_status 3 "$RAP" close -b 2
"$RAP" kill pos
# ...and within the window, never across the session's other windows.
win_block=$("$RAP" run -s demo -- /bin/sh -c 'sleep 30')
expect_status 3 "$RAP" close -s demo -b 2
"$RAP" close -b "$win_block"
"$RAP" zoom -s demo -b "$block"
"$RAP" focus -s demo -b 1
"$RAP" session inspect demo | grep -q 'windows: 1' || fail "session inspect"
"$RAP" --json session inspect demo | grep -q '"type":"vertical"' || fail "split layout"
"$RAP" block inspect -s demo -b "$block" | grep -q 'flavor: terminal.shell' || fail "block inspect"
"$RAP" close -b "$block"
"$RAP" --json session inspect demo | grep -q '"type":"vertical"' && fail "closed block still in layout"

# Memory stats list every block, in text and as JSON.
"$RAP" server stats | grep -q '^BLOCK ' || fail "server stats"
"$RAP" --json server stats | grep -q '"rows":[0-9]*,"primary":{"pages":{"pages":' || fail "server stats --json"

# Keys reach the program.
"$RAP" send-key -s demo e c h o Space k e y s Enter
wait_capture demo keys

# run --wait and wait pass the child's status through.
expect_status 7 "$RAP" run -s demo --wait -- /bin/sh -c 'exit 7'
block=$("$RAP" run -s demo -- /bin/sh -c 'exit 5')
expect_status 5 "$RAP" wait -b "$block"
# Even once the block is gone, and writing to it then fails.
block=$("$RAP" run -s demo -- true)
expect_status 0 "$RAP" wait -b "$block"
expect_status 0 "$RAP" wait -b "$block"
expect_status 1 "$RAP" send -b "$block" x

# Events stream as JSON lines.
"$RAP" events >"$tmp/events" &
events=$!
sleep 0.3
"$RAP" run -s demo -- /bin/sh -c 'printf "\033]0;hello\007"; sleep 0.2' >/dev/null
sleep 0.8
kill $events 2>/dev/null || true
wait $events 2>/dev/null || true
grep -q '"event":"block_created"' "$tmp/events" || fail "no block_created event"
grep -q '"event":"title_changed".*"title":"hello"' "$tmp/events" || fail "no title_changed event"
grep -q '"event":"child_exited"' "$tmp/events" || fail "no child_exited event"

# Program status reports carry their message and a timestamp.
"$RAP" events >"$tmp/events" &
events=$!
sleep 0.3
# "aGkgdGhlcmU=" is "hi there" in base64.
"$RAP" run -s demo -- /bin/sh -c "printf '\033]7501;state=done:msg=aGkgdGhlcmU=\033\\\\'; sleep 0.2" >/dev/null
sleep 0.8
kill $events 2>/dev/null || true
wait $events 2>/dev/null || true
grep -q '"event":"program_status_changed".*"state":"done".*"msg":"hi there".*"updated_at":[0-9]' "$tmp/events" ||
  fail "no program_status_changed event with a message and time: $(grep program_status "$tmp/events")"

# A program speaking the program status protocol with the shell function
# from its specification. block call reads back every record it left.
cat >"$tmp/status.sh" <<'EOF'
status() {
  printf '\033]7501;state=%s:msg=%s\033\\' "$1" "$(printf '%s' "$2" | base64 | tr -d '\n')"
}
status working "Syncing photos"
printf '\033]7501;state=blocked:kind=question:id=sync/ask:app=rsync\007'
true && status done "Photos synced" || status error "rsync failed"
exec sleep 30
EOF
status_block=$("$RAP" run -s demo -- /bin/sh "$tmp/status.sh")
i=0
until "$RAP" block call -b "$status_block" program_status | grep -q '"msg":"Photos synced"'; do
  i=$((i + 1))
  [ $i -lt 100 ] || fail "block call program_status never showed done: $("$RAP" block call -b "$status_block" program_status)"
  sleep 0.05
done
"$RAP" block call -b "$status_block" program_status >"$tmp/out"
grep -q '{"id":"sync/ask","state":"blocked","kind":"question","msg":null,"progress":null,"app":"rsync"' "$tmp/out" ||
  fail "block call program_status lost the child record: $(cat "$tmp/out")"
grep -q '{"id":null,"state":"done","kind":null,"msg":"Photos synced"' "$tmp/out" ||
  fail "block call program_status lost the root record: $(cat "$tmp/out")"

# block call shows the foreground program and lists its directory.
mkdir -p "$tmp/tree/a/b" "$tmp/tree/.git" "$tmp/tree/node_modules/x"
touch "$tmp/tree/a/b/c.txt" "$tmp/tree/.git/HEAD" "$tmp/tree/node_modules/x/y.js"
fg_block=$(cd "$tmp/tree" && "$RAP" run -s demo -- /bin/sh -c 'exec sleep 30')
i=0
until "$RAP" block call -b "$fg_block" process | grep -q '"foreground":{"pid":[0-9]*,"name":"sleep"'; do
  i=$((i + 1))
  [ $i -lt 100 ] || fail "block call process never showed sleep: $("$RAP" block call -b "$fg_block" process)"
  sleep 0.05
done
"$RAP" block call -b "$fg_block" list_dir depth=3 >"$tmp/out"
grep -q '{"name":"a/b/c.txt","kind":"file"}' "$tmp/out" || fail "list_dir missed a/b/c.txt: $(cat "$tmp/out")"
grep -q '"name":".git/HEAD"' "$tmp/out" && fail "list_dir descended into .git"
"$RAP" block call -b "$fg_block" list_dir path=a query=C.TXT depth=4 | grep -q '"entries":\[{"name":"b/c.txt"' ||
  fail "list_dir query"
expect_status 1 "$RAP" block call -b "$fg_block" list_dir path=nope
expect_status 2 "$RAP" block call -b "$fg_block" list_dir oops
expect_status 2 "$RAP" block call -b "$fg_block" list_dir path=2024
expect_status 2 "$RAP" block call -b "$fg_block" list_dir depth=0
"$RAP" close -b "$fg_block"

# Stopping removes the socket, and without autostart nothing answers.
"$RAP" server stop
[ ! -e "$RAP_SERVER" ] || fail "socket still exists after server stop"
expect_status 4 env RAP_AUTOSTART=0 "$RAP" ls
expect_status 4 env RAP_AUTOSTART=0 "$RAP" new x

# The server exits on its own once idle.
"$RAP" server start --idle-timeout 0.5
"$RAP" new idle -- /bin/sh >/dev/null
"$RAP" kill idle
i=0
while [ -e "$RAP_SERVER" ]; do
  i=$((i + 1))
  [ $i -lt 100 ] || fail "idle server did not exit"
  sleep 0.05
done

echo "e2e: ok"
