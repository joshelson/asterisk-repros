#!/usr/bin/env python3
"""
Loadgen for the jitterbuffer-disable-bridgewait reproducer.

The dialplan: Answer → JITTERBUFFER(type)=default → Wait(0.2) →
              JITTERBUFFER(disabled)= → Wait(5) → UserEvent(SUCCESS) → Hangup

In the buggy case the Wait(5) spins at 100% CPU on the closed timer fd instead
of sleeping.  With N concurrent spinning calls on M cores each thread is
CPU-starved, so:
  - The 5-second Wait takes N/M × 5 seconds of wall time.
  - UserEvents don't arrive within the run window  → fail = originates - ok.
  - Thread CPU stays at 100% throughout the injection window (measured via /proc).

Two metrics are emitted in RESULT / POST_TAIL lines:
  fail_pct       — % of originates with no UserEvent received (call-level)
  high_cpu_pct   — % of 0.5-s samples where any asterisk thread was ≥ CPU_THRESHOLD
  peak_cpu        — highest single-thread CPU% seen in the run

RESULT label=... originates=N ok=K fail=F fail_pct=X peak_cpu=Y high_cpu_pct=Z
POST_TAIL label=... window=A..Bs ok=K fail=F fail_pct=X post_peak_cpu=Y post_high_cpu_pct=Z
"""
import argparse
import collections
import os
import socket
import subprocess
import sys
import threading
import time
import uuid

CPU_THRESHOLD = 80.0    # % of one core considered "spinning"
CPU_SAMPLE_HZ = 2.0     # samples per second


def _send(sock, action):
    payload = "".join(f"{k}: {v}\r\n" for k, v in action.items()) + "\r\n"
    sock.sendall(payload.encode("utf-8"))


class AMI:
    def __init__(self, host, port, user, secret):
        self.sock = socket.create_connection((host, port), timeout=10)
        self.sock.settimeout(None)
        self._buf = b""
        self._read_line()  # banner
        _send(self.sock, {"Action": "Login", "Username": user,
                          "Secret": secret, "Events": "on"})
        self._wait_response("Success")

    def _read_line(self):
        while b"\r\n" not in self._buf:
            chunk = self.sock.recv(8192)
            if not chunk:
                raise EOFError("AMI socket closed")
            self._buf += chunk
        line, _, self._buf = self._buf.partition(b"\r\n")
        return line.decode("utf-8", errors="replace")

    def read_message(self):
        msg = {}
        while True:
            line = self._read_line()
            if not line:
                return msg
            if ":" in line:
                k, _, v = line.partition(":")
                msg[k.strip()] = v.strip()

    def _wait_response(self, want):
        while True:
            msg = self.read_message()
            if msg.get("Response") == want:
                return msg
            if msg.get("Response") == "Error":
                raise RuntimeError(f"AMI error: {msg}")

    def send(self, action):
        if "ActionID" not in action:
            action["ActionID"] = uuid.uuid4().hex
        _send(self.sock, action)
        return action["ActionID"]

    def close(self):
        try:
            _send(self.sock, {"Action": "Logoff"})
        except Exception:
            pass
        self.sock.close()


def get_ast_pid():
    for src in ["/var/run/asterisk/asterisk.pid",
                "/var/run/asterisk.pid"]:
        try:
            return int(open(src).read().strip())
        except Exception:
            pass
    try:
        return int(subprocess.check_output(
            ["pgrep", "-x", "asterisk"],
            stderr=subprocess.DEVNULL).decode().strip().splitlines()[0])
    except Exception:
        return None


def read_thread_ticks(pid):
    """Return {tid: utime+stime} from /proc/pid/task/*/stat."""
    result = {}
    try:
        for tid in os.listdir(f"/proc/{pid}/task"):
            try:
                with open(f"/proc/{pid}/task/{tid}/stat") as f:
                    fields = f.read().split()
                result[tid] = int(fields[13]) + int(fields[14])
            except Exception:
                pass
    except Exception:
        pass
    return result


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=5038)
    p.add_argument("--user", default="loadtest")
    p.add_argument("--secret", default="loadtest")
    p.add_argument("--duration", type=int, default=40,
                   help="total run duration in seconds")
    p.add_argument("--inject-stop-after", type=float, default=10,
                   help="stop originating after N seconds; rest is observation")
    p.add_argument("--cps", type=float, default=4.0,
                   help="originates per second")
    p.add_argument("--jb-type", default="adaptive",
                   choices=["adaptive", "fixed"],
                   help="jitterbuffer type to test")
    p.add_argument("--wait-type", default="wait",
                   choices=["wait", "bridgewait"],
                   help="poll-loop path that follows JITTERBUFFER(disabled)=")
    p.add_argument("--context", default="jb-bug-loop")
    p.add_argument("--user-event", default="repro_result")
    p.add_argument("--label", default="run")
    args = p.parse_args()

    started_at = time.time()
    inject_stop_at = started_at + args.inject_stop_after
    end_at = started_at + args.duration

    bucket_ok   = collections.defaultdict(int)
    bucket_fail = collections.defaultdict(int)
    bucket_lock = threading.Lock()
    cpu_samples = []   # [(elapsed_sec, max_thread_cpu_pct)]
    cpu_lock    = threading.Lock()
    counters    = collections.Counter()
    stop        = threading.Event()

    def bump_ok():
        sec = int(time.time() - started_at)
        with bucket_lock:
            bucket_ok[sec] += 1

    # ── CPU monitor ────────────────────────────────────────────────────
    def cpu_monitor():
        hz = os.sysconf(os.sysconf_names["SC_CLK_TCK"])
        pid = None
        for _ in range(20):
            pid = get_ast_pid()
            if pid:
                break
            time.sleep(0.5)
        if not pid:
            return
        prev_ticks = read_thread_ticks(pid)
        prev_wall  = time.time()
        interval   = 1.0 / CPU_SAMPLE_HZ
        while not stop.is_set():
            time.sleep(interval)
            now_wall   = time.time()
            now_ticks  = read_thread_ticks(pid)
            elapsed    = now_wall - prev_wall
            if elapsed > 0 and now_ticks:
                max_pct = max(
                    ((now_ticks.get(tid, 0) - prev_ticks.get(tid, 0)) / hz / elapsed * 100.0)
                    for tid in now_ticks
                )
                with cpu_lock:
                    cpu_samples.append((now_wall - started_at, max_pct))
            prev_ticks = now_ticks
            prev_wall  = now_wall

    # ── AMI event loop ─────────────────────────────────────────────────
    ctrl   = AMI(args.host, args.port, args.user, args.secret)
    listen = AMI(args.host, args.port, args.user, args.secret)

    def ctrl_drain():
        while not stop.is_set():
            try:
                ctrl.read_message()
            except Exception:
                return

    def event_loop():
        while not stop.is_set():
            try:
                msg = listen.read_message()
            except Exception:
                return
            if (msg.get("Event") == "UserEvent"
                    and msg.get("UserEvent") == args.user_event):
                status = msg.get("status") or msg.get("Status") or "NONE"
                if status == "SUCCESS":
                    counters["ok_total"] += 1
                    bump_ok()
                else:
                    counters["fail_total"] += 1

    threading.Thread(target=event_loop,   daemon=True).start()
    threading.Thread(target=ctrl_drain,   daemon=True).start()
    threading.Thread(target=cpu_monitor,  daemon=True).start()

    # ── originate loop ─────────────────────────────────────────────────
    while time.time() < inject_stop_at:
        elapsed = time.time() - started_at
        target  = int(elapsed * args.cps) + 1
        while counters["originates_sent"] < target:
            ctrl.send({
                "Action":   "Originate",
                "Channel":  f"Local/s@{args.context}/n",
                "Context":  args.context,
                "Exten":    "s",
                "Priority": "1",
                "Async":    "true",
                "Variable": f"JB_TYPE={args.jb_type},JB_WAIT_TYPE={args.wait_type}",
                "CallerID": "loadtest",
            })
            counters["originates_sent"] += 1
        time.sleep(0.05)

    # drain window: wait for UserEvents + final CPU samples
    drain_until = end_at + 5
    while time.time() < drain_until:
        time.sleep(0.5)
    stop.set()

    # ── compute metrics ────────────────────────────────────────────────
    ok          = counters["ok_total"]
    # calls that never emitted a UserEvent count as failures
    fail        = max(0, counters["originates_sent"] - ok) + counters["fail_total"]
    total       = ok + fail
    fail_pct    = (100.0 * fail / total) if total else 0.0

    with cpu_lock:
        samples_all  = list(cpu_samples)

    peak_cpu     = max((s[1] for s in samples_all), default=0.0)
    high_count   = sum(1 for s in samples_all if s[1] >= CPU_THRESHOLD)
    n_samples    = len(samples_all)
    high_cpu_pct = (100.0 * high_count / n_samples) if n_samples else 0.0

    inj_end = int(args.inject_stop_after)
    dur     = args.duration

    # ── per-second table ───────────────────────────────────────────────
    print()
    print(f"=== {args.label}  jb_type={args.jb_type}  wait_type={args.wait_type} ===")
    print(f"originates_sent: {counters['originates_sent']}")
    print(f"ok_total:        {ok}")
    print(f"fail_total:      {fail}")
    print(f"fail_pct:        {fail_pct:.2f}%")
    print(f"peak_cpu_pct:    {peak_cpu:.1f}%")
    print(f"high_cpu_pct:    {high_cpu_pct:.1f}%  (≥{CPU_THRESHOLD:.0f}% threshold)")
    print(f"cpu_samples:     {n_samples}")
    print()
    print("sec  phase  ok  max_cpu%")
    print("---  -----  --  --------")
    for sec in range(dur + 6):
        ok_s  = bucket_ok.get(sec, 0)
        phase = "inject" if sec < inj_end else "obs   "
        with cpu_lock:
            cpu_win = [s[1] for s in cpu_samples if int(s[0]) == sec]
        cpu_str = f"{max(cpu_win):.0f}%" if cpu_win else "-"
        print(f"{sec:>3}  {phase}  {ok_s:>2}  {cpu_str:>8}")

    print(
        f"RESULT label={args.label} "
        f"jb_type={args.jb_type} wait_type={args.wait_type} "
        f"originates={counters['originates_sent']} "
        f"ok={ok} fail={fail} fail_pct={fail_pct:.2f} "
        f"peak_cpu={peak_cpu:.1f} high_cpu_pct={high_cpu_pct:.1f}"
    )

    # POST_TAIL: observation window after injection stops
    post_ok   = sum(bucket_ok.get(s, 0) for s in range(inj_end, dur))
    post_fail = max(0, counters["originates_sent"] - post_ok - ok + post_ok)
    with cpu_lock:
        post_cpu = [s[1] for s in cpu_samples if s[0] >= inj_end]
    post_peak     = max(post_cpu, default=0.0)
    post_high     = sum(1 for v in post_cpu if v >= CPU_THRESHOLD)
    post_n        = len(post_cpu)
    post_high_pct = (100.0 * post_high / post_n) if post_n else 0.0
    post_total    = post_ok + max(0, counters["originates_sent"] - ok)
    post_fail_pct = (100.0 * max(0, counters["originates_sent"] - ok) / post_total) \
                    if post_total else 0.0

    print(
        f"POST_TAIL label={args.label} "
        f"window={inj_end}..{dur}s "
        f"ok={post_ok} fail_pct={post_fail_pct:.2f} "
        f"post_peak_cpu={post_peak:.1f} post_high_cpu_pct={post_high_pct:.1f}"
    )

    try:
        ctrl.close()
        listen.close()
    except Exception:
        pass


if __name__ == "__main__":
    sys.exit(main())
