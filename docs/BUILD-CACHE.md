# Compiler cache: how reuse works, its rules and its known limits

What the compiler cache shares between builds, worktrees and jobs, why each boundary is where
it is, and what is measured to be wrong today. Source owns the details; this file owns the
rules, the reasons and the measurements.

## Two layers

| Layer | Where | Who shares it |
|---|---|---|
| Local project cache | `out/debug/.cache` or `out/release/.cache` under the working directory, unless a root is chosen (see Controls) | one working directory, one job |
| Global store | `$HOME/.metascript/cache/` (`USERPROFILE` on Windows) unless a root is chosen: `store/`, `headers/`, `prelude/`, `stamps/`, `cc/` | every worktree and job that resolves the same root |

The local cache holds per-file fingerprints, emitted C, objects and link records for one tree.
The global store holds native objects keyed by content, header records and the prelude pack, so
a second worktree restores what the first compiled instead of compiling it again.

Code: `src/utils/cachePaths.ms` (`localCacheDir`, `globalCacheRoot`: the one place a root is
resolved), `src/compiler/options.ms` (`applyCacheConfig`), `src/compiler/cache.ms` (`initCache`, `objectStoreKey`,
`nativeStoreSource`, `moduleStoreSource`, `storeManifest`, `restoreModuleObject`,
`publishToStore`, `collectGlobalCache`), `src/utils/stampDirs.ms` (`collectStaleEntries`,
`markUsed`), `src/checker/preludePack.ms` (`packBase`, `packRoot`).
Package downloads in `$HOME/.metascript/cache/extracted` belong to the package manager
(`src/compiler/package/cache.ms`), and `$HOME/.metascript/cache/gate-ctl` to `tools/gate.sh`
(`CTL_CACHE`); neither is part of the compiler cache, and neither moves with a chosen global
root. `objects/` is written by older compilers only.

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
- **A hit is only as correct as its recorded inputs.** A header that appears later is an input
  only through a literal `__has_include` name; see below.

## Controls

Each root is chosen by the first source that names it; a relative path resolves against the
working directory for the command line and the environment, and against the project root for
`build.ms`:

| What | Command line | Environment | `build.ms` `build:` | Default |
|---|---|---|---|---|
| local cache | `--cache-dir=<dir>` | `MSC_CACHE_DIR` | `cacheDir` | `out/<mode>/.cache` |
| global store | `--global-cache-dir=<dir>` | `MSC_GLOBAL_CACHE_DIR` | `globalCacheDir` | `$HOME/.metascript/cache` |
| sharing | `--global-cache` / `--no-global-cache` | — | `globalCache: false` | on |

`MSC_NO_GLOBAL_CACHE=<nonempty>` turns the global store and the prelude pack off and wins over
every source above, so a job can always isolate itself. `MSC_NO_PRELUDE_PACK=<nonempty>` turns
only the prelude pack off. A chosen local root holds both debug and release.

```ts
// build.ms
const config = { build: { cacheDir: "out/cache", globalCacheDir: "/fast/msc-cache" } };
export default config;
```

`build.ms` cache fields must be direct string or boolean literals; an empty string, a control
character, a spread or a computed value is an error naming the field, not a silent default.
The perf runner (`src/test/perf/run.ms`) disables the global store on purpose to time
compilation itself; keep it so.

## Collection

The global store has no byte budget; an age sweep bounds it. On each invocation, at most once an
hour per bucket, `collectGlobalCache` removes an entry not written or used for seven days, and
a temporary file of an entry left over an hour:

| Bucket | Entry | Refreshed on use |
|---|---|---|
| `store/<shard>/` | `<key>.m` with its `<key>.o` | yes, at most hourly |
| `headers/<shard>/` | `<key>.hi` | yes, at most hourly |
| `stamps/` | `<key>.sum`, `.files`, `.exe` | no; a miss recomputes the memo |
| `prelude/<stamp>/` | `<key>.pk` with its `.deps`, after each pack write | no |

The collector deletes only files with those names, record before companion, so a reader never
finds a companion without its record; it never enters a directory whose real path leaves the
bucket, and it removes a shard only when `rmdir` finds it empty. A foreign file, a symlinked
directory and anything outside the buckets are left alone. `cc/` (compiler identity memos,
about a megabyte) is not collected. The model is the build cache trim of a mainstream toolchain:
owned suffixes, mtime refreshed on use at most hourly, trim at most once per period.

## Known limits, measured

**A header that appears later.** Every layer records the headers a compile read; a header it
looked for and missed is recorded too, from the `__has_include` and `__has_include_next` names
written as literals in the source and the headers it read. Beside each dependency file, `<dep>.q`
lists the searched directories and those names; the object fingerprint, the project record
(`?` entries) and the store manifest hash which of them exist. The searched directories include
the compiler's own list (`<cc> -E -v`, remembered per compiler, flags and the environment that
moves it: `CPATH`, `C_INCLUDE_PATH`, `SDKROOT`, `DEVELOPER_DIR` and their kin), and that list is
part of every key, so switching such a variable misses. Names match case-insensitively and record
the spelling on disk. Three shapes are never trusted, so their object is recompiled on every
build and never published to the store: a name only a macro supplies (`__has_include(NAME)`), a
name outside ASCII (two Unicode normal forms can name one file), and a compiler whose search list
could not be read.

The price is paid on every up-to-date build, which now reads each object's `<dep>.q` and its
presence memo (`<cache>/presence/`) and walks only directories whose stamp moved. On RTX Linux,
2026-10-28, a project with one `@compile` source including `<stdio.h>`, global store on,
`perf stat` task-clock of a no-op `msc build`, base and candidate interleaved, 80 runs each, two
rounds: `149ed6202` median 16.8 and 17.4 ms, `776ea3b32` 18.9 and 19.8 ms, about 2.3 ms more.
The extra time is mostly kernel reads of those files; user CPU differed by about 0.4 ms in an
earlier profile of the same change. A larger project or the macOS cost is not measured.

`src/test/cache/run.ms` is the cache lane (`tools/gate.sh` lane `cache`, chosen when
`cache`/`cc`/`compile`/`toolchain` or the lane changes, and in the release ladder): 22
input changes on the project record, the local objects and the store, each warm build compared
with a build from an empty cache, 132 checks. On macOS arm64, 2026-10-27, the compiler before
this arc (`6b7294f60`) failed 38 of them and the arc before the search-list fix (`98474fe84`)
23; on RTX Linux, 2026-10-28, the fix (`776ea3b32`) failed none, in 347 s. The fix has not run the lane on
macOS yet, so its macOS-only rows (framework headers, a case-insensitive volume) are unmeasured. Older compilers still miss these; with one of them, a build that adds such a
header needs an edited source, or an empty `MSC_CACHE_DIR` together with `MSC_NO_GLOBAL_CACHE=1`.

**Older compilers delete files they do not own.** A compiler built before the collector above
deletes any entry in `objects/`, `store/` and `headers/` (and `prelude/`) whose modification
time is over seven days old, without checking that it wrote it, and follows a directory symlink
in those buckets. Measured on installed `e5c088569` (tree `1306fdabb`, binary SHA-256
`337aa628…f89a3`), macOS arm64, fresh `HOME`, one `msc version` each:

| Fixture | Result |
|---|---|
| old foreign file in `objects/`, `store/`, `headers/` | deleted in all three |
| young foreign file in each bucket, any file outside them | kept |
| same fixtures with `MSC_NO_GLOBAL_CACHE=1` | all kept |
| symlink in `objects/` to an old directory outside the cache | file outside the cache deleted, exit 0 |
| symlink to a young directory holding an old file | file outside the cache deleted, exit 0 |

While any such compiler can run against a root, keep nothing but compiler output in its
buckets and link nothing into them. `nativeBuildBoundary.ms` groups `cache-preservation`,
`cache-symlink` and `cache-local-preservation` pin both sides: red on the old compiler, green on
the current one. std `removeAll` removes a link itself, the root included, and never walks
through it (`src/test/lang/fsRemoveAll.ms`).

**No byte budget.** The only bound on the global store is the seven-day age above; a busy week
of worktrees grows it without limit (this Mac, 2026-10-27: `store/` 17 GB, `prelude/` 7.0 GB,
`stamps/` 182 MB, `headers/` 179 MB). Gate hosts run their own disk-pressure cleanup between
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
