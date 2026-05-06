#!/usr/bin/env python3
"""
Generic AMI-driven load + reload + measurement harness.

Connects to Asterisk's AMI, fires concurrent Originate actions into a
configurable dialplan context, optionally triggers `module reload`s on
a fixed interval, and measures success/failure rate via UserEvents
emitted by the dialplan.

The dialplan should emit:

    UserEvent(repro_result, status: SUCCESS)         (good)
    UserEvent(repro_result, status: FAIL_<reason>)   (bad)

Anything other than 'SUCCESS' is treated as a failure.

Usage example:
  loadgen.py --duration 25 --reload-stop-after 18 \\
      --reload-period 1 --reload-target res_odbc.so \\
      --context __REPRO_NAME__-loop --label baseline
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


def _send(sock, action):
    payload = "".join(f"{k}: {v}\r\n" for k, v in action.items()) + "\r\n"
    sock.sendall(payload.encode("utf-8"))


class AMI:
    def __init__(self, host, port, user, secret):
        self.sock = socket.create_connection((host, port), timeout=10)
        self.sock.settimeout(None)
        self._buf = b""
        self._read_line()  # banner
        _send(self.sock, {
            "Action": "Login",
            "Username": user,
            "Secret": secret,
            "Events": "on",
        })
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


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=5038)
    p.add_argument("--user", default="loadtest")
    p.add_argument("--secret", default="loadtest")
    p.add_argument("--duration", type=int, default=25)
    p.add_argument("--cps", type=float, default=8.0,
                   help="originates per second (steady cadence)")
    p.add_argument("--iterations", type=int, default=1500,
                   help="iterations per call (controls call duration)")
    p.add_argument("--reload-period", type=float, default=1.0,
                   help="seconds between reloads (0 disables reloads)")
    p.add_argument("--reload-stop-after", type=float, default=None,
                   help="stop firing reloads after N seconds; rest of "
                        "duration is observation")
    p.add_argument("--reload-target", default="",
                   help="module to reload (empty = bare 'module reload')")
    p.add_argument("--context", default="__REPRO_NAME__-loop",
                   help="dialplan context to originate into")
    p.add_argument("--user-event", default="repro_result",
                   help="UserEvent name the dialplan emits")
    p.add_argument("--label", default="run")
    # Postgres sampling (optional — leave --pg-host unset to skip)
    p.add_argument("--pg-host", default=None)
    p.add_argument("--pg-port", default="5432")
    p.add_argument("--pg-user", default="asterisk")
    p.add_argument("--pg-pass", default="asterisk")
    p.add_argument("--pg-db", default="asterisk")
    p.add_argument("--pg-sample-period", type=float, default=0.5)
    args = p.parse_args()

    if args.reload_stop_after is None:
        args.reload_stop_after = args.duration

    bucket_total = collections.defaultdict(lambda: collections.Counter())
    bucket_lock = threading.Lock()

    started_at = time.time()

    def bump(status):
        sec = int(time.time() - started_at)
        with bucket_lock:
            bucket_total[sec][status] += 1
            bucket_total[sec]["__total__"] += 1
            if status != "SUCCESS":
                bucket_total[sec]["__fail__"] += 1
            else:
                bucket_total[sec]["__ok__"] += 1

    pg_samples = []

    ctrl = AMI(args.host, args.port, args.user, args.secret)
    listen = AMI(args.host, args.port, args.user, args.secret)

    stop = threading.Event()
    end_at = started_at + args.duration
    reload_stop_at = started_at + args.reload_stop_after

    counters = collections.Counter()

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
            if msg.get("Event") == "UserEvent" and msg.get("UserEvent") == args.user_event:
                # UserEvent body fields preserve case from dialplan.
                status = msg.get("status") or msg.get("Status") or "NONE"
                counters[f"status:{status}"] += 1
                if status == "SUCCESS":
                    counters["ok_total"] += 1
                else:
                    counters["fail_total"] += 1
                bump(status)

    def reload_loop():
        if args.reload_period <= 0:
            return
        cmd = ("module reload " + args.reload_target).strip()
        cmd = cmd if cmd != "module reload" else "module reload"
        while not stop.is_set() and time.time() < reload_stop_at:
            ctrl.send({"Action": "Command", "Command": cmd})
            counters["reloads_sent"] += 1
            time.sleep(args.reload_period)

    def pg_sample_loop():
        if not args.pg_host:
            return
        env = os.environ.copy()
        env["PGPASSWORD"] = args.pg_pass
        sql = ("SELECT count(*) FROM pg_stat_activity "
               "WHERE datname = current_database() "
               "AND application_name <> 'pg_loadgen_sampler';")
        while not stop.is_set():
            try:
                out = subprocess.check_output(
                    [
                        "psql", "-h", args.pg_host, "-p", args.pg_port,
                        "-U", args.pg_user, "-d", args.pg_db,
                        "-At", "-c",
                        f"SET application_name = 'pg_loadgen_sampler'; {sql}",
                    ],
                    env=env, stderr=subprocess.DEVNULL, timeout=2,
                ).decode().strip().splitlines()
                count = int(out[-1]) if out else -1
                pg_samples.append((time.time() - started_at, count))
            except Exception:
                pg_samples.append((time.time() - started_at, -1))
            time.sleep(args.pg_sample_period)

    threading.Thread(target=event_loop, daemon=True).start()
    threading.Thread(target=ctrl_drain, daemon=True).start()
    threading.Thread(target=reload_loop, daemon=True).start()
    threading.Thread(target=pg_sample_loop, daemon=True).start()

    while time.time() < end_at:
        elapsed = time.time() - started_at
        target_total = int(elapsed * args.cps) + 1
        while counters["originates_sent"] < target_total:
            ctrl.send({
                "Action": "Originate",
                "Channel": f"Local/s@{args.context}/n",
                "Context": args.context,
                "Exten": "s",
                "Priority": "1",
                "Async": "true",
                "Variable": f"N={args.iterations}",
                "CallerID": "loadtest",
            })
            counters["originates_sent"] += 1
        time.sleep(0.05)

    drain_until = time.time() + 5
    while time.time() < drain_until:
        time.sleep(0.5)
    stop.set()

    ok = counters["ok_total"]
    fail = counters["fail_total"]
    total = ok + fail
    fail_pct = (100.0 * fail / total) if total else 0.0

    by_status = sorted(
        ((k.split(":", 1)[1], v) for k, v in counters.items() if k.startswith("status:")),
        key=lambda kv: -kv[1],
    )

    print()
    print(f"=== {args.label} ===")
    print(f"originates_sent: {counters['originates_sent']}")
    print(f"reloads_sent:    {counters['reloads_sent']}")
    print(f"ok_total:        {ok}")
    print(f"fail_total:      {fail}")
    print(f"fail_pct:        {fail_pct:.2f}%")
    print(f"by_status:       {by_status}")

    print()
    print("time  ok    fail  status_breakdown                    pg_conns")
    print("----  ----  ----  ---------------------------------    --------")
    for sec in range(args.duration + 5):
        b = bucket_total.get(sec, collections.Counter())
        ok_s = b.get("__ok__", 0)
        fail_s = b.get("__fail__", 0)
        pg_window = [c for (t, c) in pg_samples if int(t) == sec and c >= 0]
        pg_avg = (sum(pg_window) / len(pg_window)) if pg_window else None
        breakdown = ",".join(
            f"{k}={v}" for k, v in b.items() if not k.startswith("__")
        ) or "-"
        pg_str = f"{pg_avg:.1f}" if pg_avg is not None else "-"
        phase = "R" if sec < args.reload_stop_after else "O"
        print(f"{sec:>3}{phase}  {ok_s:>4}  {fail_s:>4}  {breakdown:<35}  {pg_str}")

    print(
        f"RESULT label={args.label} "
        f"originates={counters['originates_sent']} "
        f"reloads={counters['reloads_sent']} "
        f"ok={ok} fail={fail} fail_pct={fail_pct:.2f} "
        f"reload_target={args.reload_target!r}"
    )

    post_window_start = int(args.reload_stop_after)
    post_window_end = args.duration
    post_ok = sum(bucket_total.get(s, {}).get("__ok__", 0)
                  for s in range(post_window_start, post_window_end))
    post_fail = sum(bucket_total.get(s, {}).get("__fail__", 0)
                    for s in range(post_window_start, post_window_end))
    post_total = post_ok + post_fail
    post_fail_pct = (100.0 * post_fail / post_total) if post_total else 0.0
    print(
        f"POST_TAIL label={args.label} "
        f"window={post_window_start}..{post_window_end}s "
        f"ok={post_ok} fail={post_fail} fail_pct={post_fail_pct:.2f}"
    )

    try:
        ctrl.close()
        listen.close()
    except Exception:
        pass


if __name__ == "__main__":
    sys.exit(main())
