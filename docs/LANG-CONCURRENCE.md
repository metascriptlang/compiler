# Concurrency

Current syntax and meaning live in [LANG.md](LANG.md):
[Promise and async/await](LANG.md#promiset--asyncawait),
[spawn](LANG.md#spawn--thread-pool-parallelism),
[typed async errors](LANG.md#promiseresultt-e--typed-async-errors) and
[actors](LANG.md#actors). Application choices and runnable compositions belong to
[the authoring standard](LANG-PREFERENCE.md#9-one-awaitable-surface-three-execution-tools).

Before changing captures, sharing, retained addresses or teardown, read
[Advanced contracts](CONTRACTS.md). An async result annotation is not a no-rejection proof;
read-onlyness alone establishes neither ownership nor permission to share mutable state.

The former implementation roadmap, runtime-internal extern examples and blanket
“complete”/“never rejects” verdicts are retired, not additional language rules.
Their history is available with `git log -- docs/LANG-CONCURRENCE.md`.
Architecture belongs to [PIPELINE.md](PIPELINE.md), not a second support checklist here.
