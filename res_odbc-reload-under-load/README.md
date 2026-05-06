# res_odbc reload-under-load

Reproduces (and verifies the fix for) a class of bugs in Asterisk's
`res/res_odbc.c` and `funcs/func_odbc.c` where a `module reload
res_odbc.so` (or a bare `module reload`, which iterates all
reload-capable modules) under high concurrency disrupts every consumer
of res_odbc — including `func_odbc`, `res_config_odbc`, and
PJSIP-realtime-driven SIP peer lookups.

**Upstream issue:** TBD (link once filed)
**Upstream PR:** TBD (link once opened)

## TL;DR — what this reproduces

Under load, every res_odbc reload:

1. Tears down every cached connection in every odbc_class pool, and
2. Briefly returns NULL from every `ast_odbc_request_obj()` call

…regardless of whether the class's configuration actually changed.
Production symptom: `func_odbc` queries fail, realtime SIP peer lookups
fail (peers go "unreachable"), only a manual reload "fixes" it.

The `realtime-loop` test scenario is more sensitive than the
`odbc-loop` scenario — confirms PJSIP realtime is hit harder than
func_odbc by the same bug.

## Prerequisites

- Docker (Docker Desktop on macOS works fine).
- A local checkout of the Asterisk source you want to test, supplied to
  the asterisk container via the bind mount in `docker/docker-compose.yml`.
  Edit that volume path if your checkout isn't at `~/dev/joshelson/asterisk`.

## Layout

```
res_odbc-reload-under-load/
├── README.md                   ← this file
├── repro.c                     ← standalone C model of the bug (no DB needed)
├── build.sh                    ← compile the C model (4 variants)
├── build-sanitized.sh          ← compile under TSan + ASan
├── run.sh                      ← run + tabulate the C model
├── docker/
│   ├── Dockerfile.asterisk
│   └── docker-compose.yml      ← Postgres + Asterisk
├── asterisk-config/            ← test rig Asterisk configs
├── loadgen/loadgen.py          ← AMI-driven load + reload + pg sampling
├── sql/init.sql                ← lookup + rt_test schemas
└── scripts/
    ├── build-asterisk.sh       ← (in-container) full build, idempotent
    ├── build-modules.sh        ← (in-container) rebuild only res_odbc + func_odbc
    ├── run-asterisk.sh         ← (in-container) start asterisk
    ├── run-matrix.sh           ← (host) full buggy/patched scenario matrix
    ├── test-runner.sh          ← (host) shorter test-runner (legacy)
    └── analyze-soak.sh         ← (host) RSS-over-time analyzer
```

## Standalone C model — fastest path to seeing the bug

A self-contained pthreads program that mocks `class_container`,
`aoro2_class_cb`, the reload sequence, and a fake connection pool.
Compile-time flags toggle each bug independently. No Docker, no DB.

```bash
./build.sh
./run.sh
```

Sample output (5 s run, 32 reader threads, reload every 50 ms):

```
variant         reloads lookup_fail   lookup_fail%   pool_misses   pool_miss%
-----------------------------------------------------------------------------
buggy           145     185,815       9.55%          4,672         0.78%
fix_delme       144     0             0.00%          4,640         0.76%
fix_preserve    142     180,644       8.36%          32            0.01%
fix_both        91      0             0.00%          32            0.01%
```

Both bugs are independent; fixing one alone leaves the other. TSan and
ASan: clean for both buggy and fixed builds.

```bash
./build-sanitized.sh
./repro_tsan_buggy 5
./repro_tsan_fixed 5
./repro_asan_fixed 5
```

## Real-Asterisk reproducer (Docker)

Builds Asterisk from a mounted source tree, talks to Postgres
`max_connections=15`. AMI-driven load fires Originates into one of two
dialplan contexts:

- `odbc-loop` — `${ODBC_LOOKUP(alice)}` (func_odbc → res_odbc path)
- `realtime-loop` — `${REALTIME_FIELD(rt_test,id,e1,value)}`
  (func_realtime → res_config_odbc → res_odbc path; same code path
  PJSIP realtime uses for `ps_endpoints`/`ps_auths`/`ps_aors`).

### Run it

```bash
cd docker
docker compose up -d
../scripts/build-asterisk.sh   # one-time, ~5–15 min
../scripts/run-matrix.sh       # full buggy/patched matrix, ~10–15 min
```

The matrix runs 12 scenarios (2 contexts × 3 reload targets ×
buggy/patched). It applies the upstream patches from a known location
inside the asterisk source tree before each "patched" run; if you're
running this against a different patchset, edit `apply_patches()` in
`scripts/run-matrix.sh`.

### Tunables (env vars)

```
DURATION=25            # seconds per run
RELOAD_STOP_AFTER=18   # stop reloads after N s; rest is observation tail
CPS=8                  # originates per second
ITERATIONS=1500        # ODBC queries per call
RELOAD_PERIOD=1.0      # seconds between reloads
```

### What to look for

- `RESULT … fail=N` — query failures during the run (lower is better).
- `POST_TAIL … fail=N` — failures *after* reloads stopped. The
  "stuck disconnected" indicator: persistent failures past the reload
  window mean the system isn't self-healing.
- `Preserved ODBC class … across reload` log line in patched runs —
  confirms the preserve path fired (one per reload).
- `Error SQLConnect … too many clients already` — the storm. Many in
  buggy runs, zero in patched runs.

## Empirical results (matrix run from this harness)

| Scenario | buggy fail / total | buggy tail | patched fail / total | patched tail |
|---|---|---|---|---|
| `odbc-loop` + `module reload res_odbc.so` | 243 / 134,560 (0.18%) | 61 (0.26%) | 0 / 93,736 | **0** |
| `odbc-loop` + `module reload func_odbc.so` | 0 / 170,853 | 0 | 0 / 57,134 | 0 |
| `odbc-loop` + `module reload` (everything) | 167 / 123,812 (0.13%) | 18 (0.08%) | 0 / 64,588 | **0** |
| `realtime-loop` + `module reload res_odbc.so` | 325 / 123,590 (0.26%) | 42 (0.18%) | 0 / 102,613 | **0** |
| `realtime-loop` + `module reload func_odbc.so` | 0 / 114,138 | 0 | 0 / 132,364 | 0 |
| `realtime-loop` + `module reload` (everything) | **380 / 90,720 (0.42%)** | **123 (0.65%)** | 0 / 112,328 | **0** |

Realtime path is hit harder than func_odbc. `func_odbc.so` reload
alone is benign. Worst case (`realtime-loop` + bare `module reload`)
matches the production symptom.

## How the patches relate to this repro

The fix is a 5-patch series in the [Asterisk PR](TBD). Each patch:

1. Two-pass class lookup so requests during the reload window don't fail.
2. Preserve unchanged classes (and pools) on reload.
3. UAF in `acf_odbc_read` (snapshot readhandle before releasing rwlock).
4. Snapshot `logging`/`slowquerylimit` in execute paths.
5. Opt-in `prewarm_pool` config to pre-populate the new class's pool
   on a config-changed reload, eliminating the storm even when DSN or
   credentials actually rotate. No-op at initial load and on
   no-config-change reloads.

This harness applies all 5 by default in the "patched" runs; comment
out individual `git apply` lines in `run-matrix.sh` to bisect.
