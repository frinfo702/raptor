#!/bin/sh
# Measure the rap server's memory the way Rex's published charts do: the
# phys_footprint of the server process, from
# proc_pid_rusage(RUSAGE_INFO_V4).ri_phys_footprint. macOS only.
#
# Usage: bench/rap-memory.sh [path/to/rap]   (default: zig-out/bin/rap)
#
# Build the binary first with `zig build rap -Doptimize=ReleaseFast` (from
# the nix dev shell: `direnv exec . zig ...`, or `nix develop -c zig ...`).
#
# Each workload runs against a fresh server on a private socket:
#
#   start   server start plus one session (one empty 80x24 block)
#   empty   additional memory per empty 80x24 block
#   filled  additional memory per 80x24 block that printed 10,000 numbered
#           72-column prose lines, after the server's idle compression
#   client  additional memory per client connection subscribed to 50
#           filled blocks, after one client has already subscribed; that
#           first subscriber's cost (the blocks' shared replay rings and the
#           snapshot-decode high-water mark) is reported on its own line
#
# Set RAP_BENCH_EMPTY, RAP_BENCH_FILLED, and RAP_BENCH_CLIENTS to change how
# many blocks or clients each workload averages over.
set -eu

[ "$(uname -s)" = Darwin ] || {
  echo "rap-memory: macOS only (phys_footprint comes from proc_pid_rusage)" >&2
  exit 1
}
RAP=${1:-zig-out/bin/rap}
case $RAP in /*) ;; *) RAP=$PWD/$RAP ;; esac
[ -x "$RAP" ] || { echo "rap-memory: no rap binary at $RAP" >&2; exit 1; }

exec /usr/bin/python3 -I - "$RAP" <<'PY'
import ctypes, json, os, shutil, socket, struct, subprocess, sys, tempfile, time

RAP = sys.argv[1]
N_EMPTY = int(os.environ.get("RAP_BENCH_EMPTY", "100"))
N_FILLED = int(os.environ.get("RAP_BENCH_FILLED", "20"))
N_CLIENTS = int(os.environ.get("RAP_BENCH_CLIENTS", "10"))
LINES = 10_000
KIB = 1024.0

libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")


def footprint(pid):
    """ri_phys_footprint: 16-byte uuid, then 7 u64 fields before it."""
    buf = ctypes.create_string_buffer(512)
    if libc.proc_pid_rusage(pid, 4, buf) != 0:  # RUSAGE_INFO_V4
        raise OSError(ctypes.get_errno(), "proc_pid_rusage failed")
    return struct.unpack_from("<Q", buf, 16 + 7 * 8)[0]


WORDS = """the of and to in is was that for on with as by at from his her
they this which or one had not but what all were when we there can an your
their said each she do how if will up other about out many then them these so
some would make like him into time has look two more write go see number no
way could people""".split()[:56]


def prose(path):
    """10,000 lines of "NNNNN words..." padded with '.' to 72 columns."""
    seed = 1
    with open(path, "w") as f:
        for n in range(1, LINES + 1):
            line = "%05d" % n
            while True:
                seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
                word = WORDS[(seed >> 16) % len(WORDS)]
                if len(line) + 1 + len(word) > 72:
                    break
                line += " " + word
            f.write(line.ljust(72, ".") + "\n")


def frame(sock):
    head = recv_exact(sock, 5)
    n, t = struct.unpack("<IB", head)
    return t, recv_exact(sock, n)


def recv_exact(sock, n):
    out = bytearray()
    while len(out) < n:
        chunk = sock.recv(n - len(out))
        if not chunk:
            raise EOFError("server closed the connection")
        out += chunk
    return bytes(out)


class Server:
    def __init__(self, tmp, name):
        self.path = os.path.join(tmp, name + ".sock")
        env = {"PATH": "/usr/bin:/bin", "HOME": tmp, "SHELL": "/bin/sh"}
        self.proc = subprocess.Popen(
            [RAP, "-S", self.path, "server", "run", "--idle-timeout", "600"],
            env=env, stdin=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(500):
            try:
                self.connect().close()
                break
            except OSError:
                time.sleep(0.01)
        else:
            raise RuntimeError("server did not start")
        self.next_id = 1

    def connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(self.path)
        return s

    def send(self, sock, method, params):
        self.next_id += 1
        msg = json.dumps({"id": self.next_id, "method": method, "params": params}).encode()
        sock.sendall(struct.pack("<IB", len(msg), 1) + msg)
        return self.next_id

    def call(self, method, params=None, sock=None):
        own = sock is None
        sock = sock or self.connect()
        try:
            want = self.send(sock, method, params or {})
            while True:
                t, payload = frame(sock)
                if t != 1:
                    continue
                msg = json.loads(payload)
                if msg.get("id") != want:
                    continue
                if "error" in msg:
                    raise RuntimeError("%s: %s" % (method, msg["error"]))
                return msg["result"]
        finally:
            if own:
                sock.close()

    def footprint(self):
        return footprint(self.proc.pid)

    def settle(self, timeout=60.0):
        """Wait out idle compression: until the footprint stops changing."""
        time.sleep(1.0)
        last = self.footprint()
        deadline = time.time() + timeout
        while time.time() < deadline:
            time.sleep(0.5)
            now = self.footprint()
            if now == last:
                return now
            last = now
        return last

    def stop(self):
        try:
            self.call("server.stop")
        except Exception:
            self.proc.kill()
        self.proc.wait(timeout=10)


EMPTY = ["/bin/sh", "-c", "printf '$ '; exec cat"]


def start_with_session(tmp, name):
    srv = Server(tmp, name)
    srv.call("session.create", {"label": "bench", "command": EMPTY})
    return srv


def add_blocks(srv, n, command):
    return [srv.call("session.new_window", {"session": "bench", "command": command})["block"]
            for _ in range(n)]


def wait_output(srv, blocks, seq):
    for b in blocks:
        for _ in range(3000):
            if srv.call("block.method", {"block": b, "method": "format"})["seq"] >= seq:
                break
            time.sleep(0.01)
        else:
            raise RuntimeError("block %s never printed all its lines" % b)


def subscribe_all(srv, blocks):
    """A client subscribed to every block, once every snapshot arrived."""
    sock = srv.connect()
    for b in blocks:
        srv.send(sock, "block.subscribe", {"block": b})
    done = 0
    while done < len(blocks):
        t, payload = frame(sock)
        if t == 2 and payload[12] & 2:  # snap, flags.last
            done += 1
    return sock


def main():
    tmp = tempfile.mkdtemp(prefix="rap-bench.", dir="/tmp")
    results = []
    try:
        text = os.path.join(tmp, "prose.txt")
        prose(text)
        # The pty turns each \n into \r\n.
        filled_seq = LINES * 74
        FILLED = ["/bin/sh", "-c", "cat %s; exec cat" % text]

        srv = start_with_session(tmp, "start")
        results.append(("Server start, one session", srv.settle(), "MiB", 12 * KIB * KIB))
        srv.stop()

        srv = start_with_session(tmp, "empty")
        f0 = srv.settle()
        add_blocks(srv, N_EMPTY, EMPTY)
        results.append(("Per empty 80x24 block (avg of %d)" % N_EMPTY,
                        (srv.settle() - f0) / N_EMPTY, "KiB", 100 * KIB))
        srv.stop()

        srv = start_with_session(tmp, "filled")
        f0 = srv.settle()
        blocks = add_blocks(srv, N_FILLED, FILLED)
        wait_output(srv, blocks, filled_seq)
        results.append(("Per block with 10k prose lines, idle (avg of %d)" % N_FILLED,
                        (srv.settle() - f0) / N_FILLED, "KiB", 2.2 * KIB * KIB))
        srv.stop()

        srv = start_with_session(tmp, "client")
        blocks = add_blocks(srv, 50, FILLED)
        wait_output(srv, blocks, filled_seq)
        # The first subscriber pays once for every block's replay ring, which
        # belongs to the block and is shared by all clients, and for the
        # allocator's high-water mark from decoding compressed pages into
        # snapshots. Report that on its own line; the per-client target is
        # the marginal cost of each client after it.
        f_idle = srv.settle()
        warm = subscribe_all(srv, blocks)
        f0 = srv.settle()
        results.append(("First subscriber, 50 filled blocks (rings, snapshot decode)",
                        f0 - f_idle, "KiB", None))
        clients = [subscribe_all(srv, blocks) for _ in range(N_CLIENTS)]
        results.append(("Per client, 50 filled blocks (avg of %d)" % N_CLIENTS,
                        (srv.settle() - f0) / N_CLIENTS, "KiB", 150 * KIB))
        for s in clients + [warm]:
            s.close()
        srv.stop()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("| Workload | phys_footprint | Target | |")
    print("|---|---|---|---|")
    failed = False
    for name, value, unit, target in results:
        div = KIB * KIB if unit == "MiB" else KIB
        if target is None:
            print("| %s | %.1f %s | (reported) | |" % (name, value / div, unit))
            continue
        ok = value <= target
        failed |= not ok
        print("| %s | %.1f %s | <= %.1f %s | %s |" % (
            name, value / div, unit, target / div, unit, "ok" if ok else "MISSED"))
    sys.exit(1 if failed else 0)


main()
PY
