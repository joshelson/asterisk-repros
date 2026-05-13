# jitterbuffer-disable-bridgewait

`JITTERBUFFER(disabled)=` leaves a closed timer fd registered on the channel,
causing any subsequent poll-based wait (`BridgeWait`, `Wait()`, `ast_waitfor()`)
to spin at 100% CPU on every thread that owns such a channel.

**Upstream issue:** https://github.com/asterisk/asterisk/issues/1762
**Fix:** `main/abstract_jb.c` — call `ast_channel_set_fd(chan, AST_JITTERBUFFER_FD, -1)`
immediately after `ast_framehook_detach()` in the `"disabled"` branch.

## TL;DR — what this reproduces

1. A channel enables a jitterbuffer (`JITTERBUFFER(adaptive)=default` or `fixed`).
2. A frame passes through the channel so the JB timer fd is fully registered.
3. The same channel then disables it with `JITTERBUFFER(disabled)=`.
4. The channel enters `Wait()` *or* `BridgeWait(default,participant,e(h))`.

In the buggy case the jitterbuffer framehook is only *marked* for deferred
destruction — the timer fd it owns is closed by `jb_framedata_destroy()` on
the next frame, but the channel fd slot (`AST_JITTERBUFFER_FD`) is never
cleared.  `poll()` on a closed fd returns `POLLNVAL` instantly on every
call, spinning the owning thread.

The fix clears the channel fd slot immediately after detaching the framehook,
so `ast_add_fd()` skips it entirely and the thread goes back to sleeping.

Two wait paths are tested:

- `wait`        — `Wait(5)` polled by the dialplan thread.  The closed fd
  pins **one** thread at ~100% CPU (a single dialplan thread spinning).
- `bridgewait` — `BridgeWait(default,participant,e(h))` exactly as in the
  upstream issue.  Each call is serviced by its own bridge channel thread,
  so the spin is **distributed across many threads** instead of pinning
  one — peak single-thread CPU is lower but the bug is the same and the
  total spin (sum across threads) is even larger.

## Prerequisites

- Docker (Docker Desktop on macOS works fine).
- A local checkout of Asterisk source mounted at `../../asterisk` relative to
  this directory (default) or set `ASTERISK_SRC=/path/to/asterisk` in the
  environment before running `docker compose`.

No database, no ODBC, no PJSIP — this bug is in the core scheduler/poll loop.

## Layout

```
jitterbuffer-disable-bridgewait/
├── README.md
├── patches/
│   └── fix-jb-fd-on-disable.patch   ← applied/reverted by run-matrix.sh
├── docker/
│   ├── Dockerfile.asterisk
│   └── docker-compose.yml
├── asterisk-config/
│   ├── asterisk.conf
│   ├── manager.conf
│   ├── modules.conf                  ← minimal: func_jitterbuffer + res_timing_timerfd
│   └── extensions.conf               ← [jb-bug-loop]: enable JB → disable JB → Wait(5) → UserEvent
├── loadgen/loadgen.py                ← AMI originate + /proc CPU sampling + RESULT/POST_TAIL output
└── scripts/
    ├── build-asterisk.sh             ← (in-container) one-time full build
    ├── build-modules.sh              ← (in-container) rebuild main/ + relink binary
    ├── run-asterisk.sh               ← (in-container) start asterisk
    └── run-matrix.sh                 ← (host) buggy/patched matrix for adaptive + fixed JB types
```

## How to run

```bash
# One-time: build the container image and Asterisk binary (~5-15 min)
cd docker
docker compose up -d
docker compose exec asterisk /scripts/build-asterisk.sh

# Run the full buggy/patched matrix (both adaptive and fixed JB types)
cd ..
scripts/run-matrix.sh
```

`run-matrix.sh` produces four `.out` files (`buggy_adaptive.out`, `buggy_fixed.out`,
`patched_adaptive.out`, `patched_fixed.out`) and prints a summary table.

## Tunables (env vars)

```
DURATION=40          # total wall-clock seconds per run
INJECT_STOP=10       # stop originating after N s; remainder is observation tail
CPS=4                # originates/second (40 total at defaults)
```

## Expected output

`peak_cpu` is the smoking gun.  Single-thread spin (`wait` variant) shows up
as one thread at ~100%; distributed spin across bridge channel threads
(`bridgewait` variant) shows up as a sustained 50-70% peak with many threads
all consuming CPU simultaneously.  Patched runs sit at single-digit %.

Actual measurements on an 8-core Docker host at default tunables (CPS=4,
40 calls per run):

```
label                            | fail% | peak_cpu | high_cpu% | post_hcpu%
---------------------------------|-------|----------|-----------|-----------
buggy_adaptive_wait              | 0.00% | 101.5%   | 14.6%     | 15.7%
buggy_adaptive_bridgewait        | 0.00% |  57.9%   |  0.0%     |  0.0%
buggy_fixed_wait                 | 0.00% | 106.6%   | 13.5%     | 11.4%
buggy_fixed_bridgewait           | 0.00% |  61.7%   |  0.0%     |  0.0%
patched_adaptive_wait            | 0.00% |   2.0%   |  0.0%     |  0.0%
patched_adaptive_bridgewait      | 0.00% |   2.0%   |  0.0%     |  0.0%
patched_fixed_wait               | 0.00% |  19.7%   |  0.0%     |  0.0%
patched_fixed_bridgewait         | 0.00% |   4.0%   |  0.0%     |  0.0%
```

- `peak_cpu`: highest single-thread CPU% seen.  >100% = single-thread spin
  (`wait`).  50-70% with high originate count = distributed bridge-channel
  spin (`bridgewait`).  Single-digit = fixed.
- `high_cpu_pct`: percentage of 0.5-second samples where any thread measured
  ≥ 80% CPU.  Catches the `wait` variant; misses the distributed
  `bridgewait` spin (no single thread reaches 80%).
- `fail_pct`: calls that never emitted the success UserEvent.  Stays at 0
  with default tunables because the host has enough cores to keep up; raise
  `CPS` or run on a small VM to force CPU starvation.
- `post_hcpu_pct`: `high_cpu_pct` but only in the observation window after
  origination stops — confirms the spin persists rather than being bursty.

## Notes

- The dialplan uses `Wait(5)` rather than `BridgeWait` so the reproducer needs
  no external peer channel or AMI hangup coordination.  The CPU-starvation math
  is identical: `poll()` spins on the closed fd regardless of which wait is used.
- `build-modules.sh` rebuilds `main/` (not a loadable `.so`) and relinks the
  `asterisk` binary because the fix lives in `main/abstract_jb.c`.
- Both `adaptive` and `fixed` JB types are affected: they share the same
  `jb_framedata` timer allocation and the same disable path in
  `ast_jb_create_framehook()`.
