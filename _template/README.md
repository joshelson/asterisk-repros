# __REPRO_NAME__

__REPRO_DESC__

**Upstream issue:** TBD
**Upstream PR:** TBD

## TL;DR — what this reproduces

Replace this paragraph with: what the bug looks like in production,
what conditions trigger it, what the user-visible symptom is, and what
log message / metric / observation indicates that the bug fired.

## Prerequisites

- Docker (Docker Desktop on macOS works fine).
- A local checkout of Asterisk source. By default the harness expects
  it at `../../asterisk` (a sibling-of-this-repo layout); override
  with `ASTERISK_SRC=/path/to/asterisk`.
- (Optional) Anything else this specific reproducer needs — a SIP UA
  binary, a particular module loaded, etc.

## Layout

```
__REPRO_NAME__/
├── README.md                   ← this file
├── docker/
│   ├── Dockerfile.asterisk     ← Linux container with Asterisk build deps
│   └── docker-compose.yml      ← service stack
├── asterisk-config/            ← asterisk configs loaded into the container
├── loadgen/loadgen.py          ← AMI-driven load + reload + measurement
├── sql/init.sql                ← schemas + seed data (if a DB is needed)
└── scripts/
    ├── build-asterisk.sh       ← (in-container) full asterisk build
    ├── build-modules.sh        ← (in-container) rebuild affected modules
    ├── run-asterisk.sh         ← (in-container) start asterisk
    └── run-matrix.sh           ← (host) buggy/patched scenario matrix
```

## How to run

```bash
cd docker
docker compose up -d
docker compose exec asterisk /scripts/build-asterisk.sh   # one-time, ~5–15 min
../scripts/run-matrix.sh                                  # buggy/patched matrix
```

## Tunables (env vars)

```
DURATION=25            # seconds per run
RELOAD_STOP_AFTER=18   # stop reloads after N s; rest is observation tail
CPS=8                  # originates per second (steady cadence)
ITERATIONS=1500        # iterations per call
RELOAD_PERIOD=1.0      # seconds between reloads
```

## Expected output

After a successful run, `scripts/run-matrix.sh` prints a summary like:

```
RESULT label=buggy_*    fail=N    fail_pct=N.NN
RESULT label=patched_*  fail=0    fail_pct=0.00

POST_TAIL label=buggy_*   fail=N    fail_pct=N.NN
POST_TAIL label=patched_* fail=0    fail_pct=0.00
```

`POST_TAIL` is the failure rate in the observation window *after*
reloads stopped — useful for confirming the system self-heals (or
doesn't, in the buggy case).

## Notes

Anything reviewers should know — environment caveats, things that are
deliberately not tested, known limitations, etc.
