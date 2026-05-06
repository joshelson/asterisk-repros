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

| Directory | Bug | Status |
|---|---|---|
| [`res_odbc-reload-under-load/`](./res_odbc-reload-under-load/) | `module reload res_odbc.so` under load disrupts every ODBC consumer (func_odbc, res_config_odbc, PJSIP realtime). | See `res_odbc-reload-under-load/README.md`. Upstream issue + PR linked there. |

## Adding a new reproducer

```
cp -r _template/ <new-bug-name>/
# Edit <new-bug-name>/README.md to describe the bug.
# Edit the configs/scripts to drive the actual repro.
```

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
