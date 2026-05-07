# asterisk-repros

Reproducible bug reproducers for [Asterisk](https://github.com/asterisk/asterisk).

Each subdirectory is a self-contained reproduction harness for one bug
(or class of bugs), with whatever Docker/Postgres/load-gen/dialplan
scaffolding is needed to demonstrate the symptom and verify a fix.

The point of this repo is **scaffolding that the upstream Asterisk repo
will not accept**: full Docker stacks, AMI load generators, sample
schemas, large SQL fixtures, etc. Patches that fix the bugs live with
the upstream PR, not here. Each reproducer here cross-references its
upstream issue/PR.

## Reproducers

| Directory | Bug / scope | Status |
|---|---|---|
| [`res_odbc-reload-under-load/`](./res_odbc-reload-under-load/) | `module reload res_odbc.so` under load disrupts every ODBC consumer (func_odbc, res_config_odbc, PJSIP realtime). | See `res_odbc-reload-under-load/README.md`. Upstream issue + PR linked there. |
| [`res_odbc-aco-conversion/`](./res_odbc-aco-conversion/) | End-to-end parse-coverage harness for the res_odbc aco-conversion PR. Comprehensive `res_odbc.conf` (~30 sections) + snapshot capture. | See `res_odbc-aco-conversion/README.md`. Reuses the reload-under-load docker stack. |

## Adding a new reproducer

```bash
bin/new-repro.sh <new-bug-name> "Short description of the bug"
```

This copies `_template/` to `<new-bug-name>/` and substitutes
placeholders (`__REPRO_NAME__`, `__REPRO_DESC__`) throughout. The
result is a complete, working scaffold:

```
<new-bug-name>/
├── README.md                ← prefilled, edit to describe the bug
├── docker/
│   ├── Dockerfile.asterisk  ← Debian + asterisk build deps + ODBC drivers
│   └── docker-compose.yml   ← postgres + asterisk, ASTERISK_SRC overridable
├── asterisk-config/         ← minimal core asterisk + AMI; add modules you need
├── loadgen/loadgen.py       ← AMI loadgen, expects UserEvent(repro_result, status: ...)
├── sql/init.sql             ← postgres seed (or remove the db service if not needed)
└── scripts/
    ├── build-asterisk.sh    ← (in-container) full build
    ├── build-modules.sh     ← (in-container) edit SRC_FILES/MODULE_DIRS for what to rebuild
    ├── run-asterisk.sh      ← (in-container) start asterisk
    └── run-matrix.sh        ← (host) buggy/patched matrix; edit `scenarios` array
```

After scaffolding, customize:
1. `README.md` — describe the bug, trigger, expected output.
2. `asterisk-config/modules.conf` — load the modules your bug needs.
3. `asterisk-config/extensions.conf` — replace the operation under
   test in the `*-loop` context.
4. `sql/init.sql` — schemas + seed data (or remove the db service).
5. `loadgen/loadgen.py` — already generic; only edit if you need
   different success-detection logic.
6. `scripts/run-matrix.sh` — edit `scenarios` for what reload
   targets you want to compare.
7. Add an entry to this README's "Reproducers" table.

### What goes in a reproducer

A repro directory should be **runnable in one command** by someone with
just Docker installed. Conventions:

```
<bug-name>/
├── README.md             ← describes bug, expected output, links to issue/PR
├── docker/
│   ├── Dockerfile.*      ← service images
│   └── docker-compose.yml
├── asterisk-config/      ← test asterisk configs (loaded into the container)
├── sql/                  ← schemas + seed data for any DB the test needs
├── loadgen/              ← scripts that drive load (AMI, SIP, ARI, etc.)
├── scripts/              ← entry points: build.sh, run-matrix.sh, etc.
└── repro.c               ← optional: standalone C model if applicable
```

### What does NOT go in here

- Patches against asterisk source. Those go in the upstream PR.
  Reproducers may reference the upstream PR/branch and apply patches at
  runtime, but the canonical home for a fix is the asterisk repo.
- Asterisk source itself. Reproducers that build asterisk should
  expect the source to be supplied via volume mount or git checkout.

### How a reproducer should report results

Reproducers should produce **machine-readable output** so before/after
comparisons are unambiguous. The convention used here:

```
RESULT label=<runlabel> ... ok=<n> fail=<n> fail_pct=<n.nn>
POST_TAIL label=<runlabel> ... ok=<n> fail=<n> fail_pct=<n.nn>
```

`POST_TAIL` is the failure rate in a designated observation window
*after* the disruption stops — a key indicator of "does the system
self-heal, or is it stuck?"

## Running a reproducer

```bash
cd <bug-name>/docker
docker compose up -d
../scripts/run-matrix.sh   # or whatever the per-repro README says
```

Each repro's `README.md` documents its specific entry points.

## License

MIT. See [LICENSE](./LICENSE).
