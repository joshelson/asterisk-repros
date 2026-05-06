# <bug-name>

One-line description of the bug.

**Upstream issue:** TBD
**Upstream PR:** TBD

## TL;DR — what this reproduces

What the bug looks like in production. What conditions trigger it.
What the user-visible symptom is.

## Prerequisites

- Docker (or whatever the harness needs).
- Asterisk source checkout if the harness builds it from source.
- Anything else specific (a SIP UA, a particular module loaded, etc.).

## Layout

```
<bug-name>/
├── README.md
├── repro.c                     (optional) standalone model
├── docker/
├── asterisk-config/
├── loadgen/
├── sql/
└── scripts/
    └── run-matrix.sh           (or whatever entry point)
```

## How to run

```bash
cd docker
docker compose up -d
../scripts/run-matrix.sh
```

## Expected output

Show a `RESULT` / `POST_TAIL` line for the buggy case and the patched
case so reviewers can confirm the bug exists and the fix works.

```
RESULT label=buggy   fail=N fail_pct=N.NN
RESULT label=patched fail=0 fail_pct=0.00
```

## Notes

Anything reviewers should know — known limitations, things that are
deliberately not tested, environment caveats, etc.
