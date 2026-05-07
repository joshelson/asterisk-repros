# res_odbc — config_options (aco_*) conversion harness

End-to-end parser exercise for the **res_odbc** aco-conversion PR.
Drives a comprehensive `res_odbc.conf` fixture (~30 sections covering
every option, every parse branch, every documented edge case) through
a running Asterisk and captures the observable output (`odbc show
all`, parse-time WARNING/ERROR log lines).

This is dev tooling — complementary to the in-tree
`tests/test_res_odbc.c` AST_TEST_DEFINE blocks that ship with the PR.
The in-tree tests cover behavioral correctness; this harness covers
file-based parse coverage and lets you eyeball the WARNING set
operators will see when their existing `res_odbc.conf` hits the new
parser.

## What it exercises

| Section group | What it pins down |
|---|---|
| `golden_allopts` / `golden_minimal` | Every option set vs. defaults |
| `golden_disabled` / `golden_no_dsn` | Skip-cases (no class registered) |
| `golden_iso_*` | Loose-prefix isolation matching (`serpent`→SERIALIZABLE etc.) |
| `golden_cache_*` | `cache_type`, `cache_size=-1`, `cache_size=garbage` |
| `golden_maxconn_*` | `max_connections=0/-5/foo/huge` |
| `golden_conntimeout_*` | `connect_timeout=0/foo` |
| `golden_negcache_*` | `negative_connection_cache=0/2.75/-1/foo` |
| `golden_slow_*` | `slow_query_limit=0/-1/foo` |
| `golden_deprecated_*` | The four obsolete pool aliases |
| `golden_bool_*` | `ast_true` quirks (typos silently → false) |
| `golden_eq_syntax` / `golden_mixed_syntax` | `=` vs `=>` lexer equivalence |

Each section is named so the WARNING/ERROR it triggers (or doesn't) is
easy to identify in the captured log.

## Reusing the reload-under-load docker stack

This harness shares the docker compose stack from
[`../res_odbc-reload-under-load/`](../res_odbc-reload-under-load/)
because both want the same Asterisk + PostgreSQL + ODBC driver setup.
Bring it up once:

```bash
cd ../res_odbc-reload-under-load/docker
docker compose up -d
```

The asterisk container builds with `--enable-dev-mode` +
`TEST_FRAMEWORK` so it picks up `tests/test_res_odbc.c` from the
mounted asterisk source tree.

## Running

```bash
# From this directory, after the docker stack is up:
./scripts/parse-golden.sh aco_baseline
```

This writes `expected/aco_baseline.snapshot` (and a few intermediate
`.raw` files). Re-run after a change and `diff` the snapshots.

## Upstream

- aco-conversion branch: `aco-conversion` on this maintainer's fork
- Upstream issue: TBD (filed by maintainer)

## What is NOT in scope here

- The reload-under-load reproducer (preserve-on-reload, prewarm_pool,
  lookup-race fix). Those land as a separate PR layered on top of the
  aco conversion. See [`../res_odbc-reload-under-load/`](../res_odbc-reload-under-load/).
- The standalone `func_odbc` UAF and execute-path logging-snapshot
  fixes — separate single-purpose upstream PRs.
