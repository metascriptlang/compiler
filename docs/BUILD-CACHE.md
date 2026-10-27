# Compiler cache: how reuse works, its rules and its known limits

What the compiler cache shares between builds, worktrees and jobs, why each boundary is where
it is, and what is measured to be wrong today. Source owns the details; this file owns the
rules, the reasons and the measurements.

## Two layers

| Layer | Where | Who shares it |
|---|---|---|
| Local project cache | `out/debug/.cache` or `out/release/.cache` under the working directory, or `MSC_CACHE_DIR` | one working directory, one job |
| Global store | `$HOME/.metascript/cache/` (`USERPROFILE` on Windows): `store/`, `objects/`, `headers/`, `prelude/` | every worktree and job of that user on that host |

The local cache holds per-file fingerprints, emitted C, objects and link records for one tree.
The global store holds native objects keyed by content, header records and the prelude pack, so
a second worktree restores what the first compiled instead of compiling it again.

Code: `src/compiler/cache.ms` (`initCache`, `globalCacheRoot`, `objectStoreKey`,
`nativeStoreSource`, `moduleStoreSource`, `storeManifest`, `restoreModuleObject`,
`publishToStore`, `collectGlobalCache`), `src/checker/preludePack.ms` (`packBase`, `packRoot`).
Package downloads in `$HOME/.metascript/cache/extracted` belong to the package manager
(`src/compiler/package/cache.ms`), and `$HOME/.metascript/cache/gate-ctl` to `tools/gate.sh`
(`CTL_CACHE`); neither is part of the compiler cache.

## What a worktree reuses from another

- **Generated modules** are keyed by the emitted C content (`moduleStoreSource`), so the same
  module compiled in another worktree is restored even though its path differs.
- **Native sources** (`@compile` C files) are keyed by their absolute path plus content
  (`nativeStoreSource`), so a C file is reused only by a build that names the same absolute
  path. Two worktrees each holding a copy of a C file compile it once each.
- **The prelude pack** is shared by every compiler build that reads the same pack format; a
  foreign compiler stamp is a miss, never a deletion.

Measured on installed v0.3.2 (tree `5d2c1980d`, macOS arm64, Apple clang 21, fresh `HOME` and
local caches): a second root building `console.log(42)` with the first root's global store
compiled 0 native sources instead of 23; a test run with a new local cache compiled 49
generated files and restored all 97 native objects. Table and commands:
[BUILD-PERF.md](BUILD-PERF.md) "Measured 2026-10-08".

## Rules

- **One job, one local cache.** Never point two concurrent jobs at one `MSC_CACHE_DIR` or one
  `out/`, and never copy another job's `out/`: the local cache is a mutable record of one tree,
  and two writers race on it (two `msc test` in the same tree already do, see
  [TESTING.md](TESTING.md)). Share through the global store instead; it is keyed by content.
- **Do not wipe `out/` or the global store to get a clean run.** Wiping re-pays every native
  compile and triggers the cold-build link race. For a cold measurement, give the job a fresh
  `MSC_CACHE_DIR` and a fresh `HOME` (or `MSC_NO_GLOBAL_CACHE=1`); that leaves everyone
  else's cache alone.
- **A miss is not a bug to optimize away.** Path, compiler and support trees, target, memory
  mode, flags and header resolution are in the key because a hit across them could produce a
  different program. Removing one of them from a key needs a measurement that output stays
  identical across it.
- **A hit is only as correct as its recorded inputs.** See the false hit below before trusting a
  hit across a header that appeared after the first build.

## Controls

| Variable | Effect |
|---|---|
| `MSC_CACHE_DIR=<dir>` | local cache in `<dir>` instead of `out/<mode>/.cache`; one directory for both debug and release |
| `MSC_NO_GLOBAL_CACHE=<nonempty>` | no global store and no prelude pack: nothing read from or written to `$HOME/.metascript/cache` by the compiler cache |
| `MSC_NO_PRELUDE_PACK=<nonempty>` | no prelude pack; the global store stays on |

There is no `build.ms` or CLI option for cache directories or sharing on `main` yet; a job that
needs another root sets these variables. The perf runner (`src/test/perf/run.ms`) disables the
global store on purpose to time compilation itself; keep it so.

## Known limits, measured

**A header that appears later is not seen (false hit).** A native source with
`#if __has_include("optional.h")` built while `optional.h` was absent, then rebuilt with a new
local cache after creating it, restored the old object and printed `11` instead of `22`;
`MSC_NO_GLOBAL_CACHE=1` printed `22`. The store records the headers a compile read, not the
ones it looked for and missed. Details: [BUILD-PERF.md](BUILD-PERF.md) "Measured 2026-10-08".
Until that is fixed, a build that adds a header found through `__has_include` or an include
path searched before an existing one needs `MSC_NO_GLOBAL_CACHE=1` or a changed source.

**Startup collection deletes files the compiler does not own.** Every invocation, including
`msc version`, runs `collectGlobalCache` (and prelude publication runs the same collector on
`prelude/`): it deletes any entry in `objects/`, `store/` and `headers/` whose modification
time is over seven days old, without checking that the compiler wrote it, and it follows a
directory symlink in those buckets. Measured on installed `e5c088569` (tree `1306fdabb`,
binary SHA-256 `337aa628…f89a3`), macOS arm64, fresh `HOME`, one `msc version` each:

| Fixture | Result |
|---|---|
| old foreign file in `objects/`, `store/`, `headers/` | deleted in all three |
| young foreign file in each bucket, any file outside them | kept |
| same fixtures with `MSC_NO_GLOBAL_CACHE=1` | all kept |
| symlink in `objects/` to an old directory outside the cache | file outside the cache deleted, exit 0 |
| symlink to a young directory holding an old file | file outside the cache deleted, exit 0 |

So never keep anything but compiler output under `$HOME/.metascript/cache/{objects,store,headers,prelude}`,
and never link those buckets to anything else. The deletion follows the link because
`collectStaleEntries` (`src/utils/stampDirs.ms`) and `removeAll` (`std/fs/index.cms`) both
classify an entry by its target, not by the link itself.

**No byte budget.** The only bound on the global store is the seven-day age above; a busy week
of worktrees grows it without limit. Gate hosts run their own disk-pressure cleanup between
jobs, owned by `~/metascript/.gate-host/README.md`.

## Rejected

Two ways to make native reuse complete were measured and dropped, because each made warm
builds slower or still missed inputs: unconditional preprocessing of every native source, and
bare snapshots of native compiler inputs (they miss `.incbin`). Numbers:
[BUILD-PERF.md](BUILD-PERF.md) "Measured 2026-10-03" and "Rejected 2026-10-05". A fix for the
false hit must not bring either back.

## Measuring reuse

Fix the consumer, source, working directory, compiler and support trees, target and flags,
then compare these states, each with a fresh fixture `HOME` and `MSC_CACHE_DIR`, never by
deleting someone's cache:

1. fresh local, fresh global;
2. the same local and global again, unchanged;
3. a new local with the global from state 1;
4. a new local with `MSC_NO_GLOBAL_CACHE=1`.

Count native compiles, generated-module compiles, dispatcher compiles and links separately
(`--verbose -t` with a counting `--cc` driver, as in the 2026-10-08 run), and record setup,
compile, restore and link time apart, because a hit count alone proves neither saved wall time
nor bounded disk. Record the tree, compiler binary hash, support-tree commit, C compiler, OS
and the resolved cache directories with every number.
