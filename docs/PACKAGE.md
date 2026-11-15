# PACKAGE — `build.ms` and the package manager

How a MetaScript project is declared and how it consumes, declares and ships packages. The schema
lives in code — `std/build/index.ms` (`BuildConfig`, `PackageMeta`) is what your `build.ms`
type-checks against, and `src/compiler/buildConfig.ms` (`loadBuildConfig`) is what reads it. This
doc covers what the code cannot say about itself: workflows, semantics, and what is actually wired.

Everything marked *measured* was run on 2026-09-22, `msc` v0.2.55 (installed build `b201f063`).
What was **not** verified is listed at the end.

## `build.ms` — the project manifest

One file, both build config and package manifest. No `package.json` beside it.

**Discovery**: the compiler walks up from the entry file (or CWD) to the nearest `build.ms`; that
directory is the project root, and every manifest operation (`msc.lock`, `.msc/bin/`, relative
`file:` deps) is relative to it (`findProjectRoot`, `src/utils/path.ms`).

**Accepted forms** (`findConfigObject`): `const config: BuildConfig = { … }; export default config;`
(the idiomatic form) and `export default { … };`. A call such as `defineConfig({ … })` stops every
command with `build: configuration must contain an object literal`. A `build.ms` that exports build nodes is the
other form ("`build.ms` as a build graph" below).

**Every field is read or refused** (`checkConfigShape`): a field msc does not read, or a value it
cannot read as a literal of its kind, stops every command and names the field and line, and the
editor reports the same on `build.ms`. Measured 2026-11-09 on a candidate built from `wt/build-graph`:
`scripts: { gate: "x" }` → `scripts: msc does not read this field; it reads entry, build, resolve,
fmt, lsp, cc, package, deps, devDeps, defines, globalImports (line 1)`; `fmt: { printwidth: 40 }` →
`fmt.printwidth: msc does not read this field`. Before, both built with exit 0.

```ms
import { BuildConfig } from "std/build";

const config: BuildConfig = {
	entry: "./src/main.ms",            // what `msc build` / `msc run` compile when no file is passed
	build: {
		target: "c",                   // "c" (default, "native" aliases it) | "js"
		outFile: "hello",              // C: output binary name
		outDir: "out",                 // JS: output directory
		optimize: "release",           // "debug" (default) | "release" (-O2)
	},
	fmt: { printWidth: 100, useTabs: true },   // read by `msc fmt` (loadFmtSection)
	package: { name: "demo", version: "0.1.0" },
	deps: {
		"greeter": "file:../libpkg",
	},
};

export default config;
```

Measured on exactly this shape (plus a `file:` dep): `msc build` → `Built 11 module(s) → hello`,
`./hello` prints the dep's output. CLI flags win over `build.ms`: a file argument overrides
`entry`, `--output=` overrides `outFile`, `--release`/`--danger` override `optimize`.

### Sections that work today

| Section | Read by | Effect |
|---|---|---|
| `entry` | `msc build` / `msc run` | default input file |
| `build.target` | `msc build` | `"js"` routes to the JS backend; anything else is C |
| `build.outFile` | `msc build` (C) | binary name |
| `build.outDir` | `msc build` (JS) | output directory |
| `build.optimize` | `msc build` | `"release"` maps to `-O2`; CLI opt flags override |
| `fmt` | `msc fmt` | formatter settings (`FmtConfig` in `std/build/index.ms`) |
| `cc` | `msc build` | C compiler selection — see below |
| `globalImports` | every command that checks code | see below |
| `lsp` | the language server only | see below |
| `package` / `deps` / `devDeps` | the package manager | see below |

### Compiler cache

`build: { cacheDir, globalCacheDir, globalCache }` choose the project's local cache, its global
store and whether it shares one; the command line and the environment win over them. Where
artifacts are cached, what other worktrees and jobs reuse and the measured limits:
[BUILD-CACHE.md](BUILD-CACHE.md). Package downloads under `~/.metascript/cache/extracted` are the
package manager's and do not move with these settings.

### `cc` — C compiler and flags

`cc.compiler`, `cc.flags`, `cc.linkFlags` apply to every build; `cc.targets` keys on `"<os>-<cpu>"`
(`linux-amd64`, `windows-arm64`, …) override them when cross-compiling that target, and each
target may carry its own `entry`. Resolution order: per-target config > `cc.*` defaults >
well-known cross-compiler (`resolveCcForTarget`, `src/compiler/buildConfig.ms`). CLI `--cc=`,
`--passC=`, `--passL=` override all of it. A target's `entry` wins over the top-level `entry`, and a
file argument wins over both: measured 2026-11-09 (candidate from `wt/build-graph`), `entry:
"src/main.ms"` with `targets: { "linux-arm64": { entry: "src/cross.ms" } }` builds `src/cross.ms`
under `msc build --cpu=arm64` (the installed `c1e2de84172` built `src/main.ms`).

### `globalImports`

Module paths whose exports land in scope of every source file, injected before command dispatch
(`src/index.ms`). `std/`-prefixed specifiers pass through; absolute paths are normalized; anything
else is joined to the project root. Entries are extension-less. Precedence: a local declaration
wins over an explicit import, an explicit import wins over the injection. An object entry is
`{ from, modulePass? }`; any other field (`names`, …) is refused, because an entry always injects
the module's full export surface.

#### `modulePass` — a build-wide module transform

`globalImports: [{ from: "./refresh", modulePass: "refreshModule" }]` names a macro exported by that
module. Before declarations are collected, every module outside std and outside the globalImports
closure is handed to it as a `Program`, and its return value replaces the module. A result that is
not a `Program`, or that changes the module's imports, is an error naming the pass. Contract pins:
`src/test/c/modulePassDiagnostics.ms`, `src/test/c/modulePassEmit.ms`, corpus
`1061-modulePassComponents`, `1062-modulePassKeepsModules`.

Turning it off for a release: keep one `config`, and let the pass switch itself off with `when`
inside its body. The macro body sees the build's defines. Measured 2026-10-06 on a dev build of
`wt/module-pass`, using a copy of 1062 whose `keepModule` returned a NumberLiteral under
`when (refresh)`: with `-d:refresh`, the pass is refused by name; without it, the oracle line prints.
`--hcr` defines `hcr` the same way (`src/compiler/options.ms`), but `when (hcr)` was not run.

```ts
export macro refreshModule(mod: Node): Node {
	when (hcr) { /* rewrite */ }
	return mod;
}
```

A pass that returns its module unchanged emits the same bytes as the same `globalImports` without
the pass. Measured on that build: 1062 gave identical C (16 modules via `--emit=c`) and identical JS
(one 190 KB bundle). The rule is pinned by `src/test/c/modulePassEmit.ms`; the pin goes red when
node flags stop crossing the macro wire. Writing `config` twice inside `when (…) { const config = … }
else { … }` also works (measured the same day), but its two copies drift.

The language server checks each `globalImports` entry as an implicit import of the project, with
the same visibility as batch checking: a module sees the entries before the first one whose import
closure reaches it, and std modules see none; module passes bind as in batch. Measured 2026-10-23
by the replay scenarios in `src/compiler/lsp/replayScenarios.ms` (a macro from a global import
expands, class and generic identity, edits reaching users, both visibility cases, a pass after a
project switch), each compared with `msc check`. A change to `build.ms` itself still needs a server
restart.

Under `--hcr`, a globalImports module with a pass that keeps a module-level `string[]` links and
reloads: `hcrModulePassReload` green on main 7aea56331e2 (2026-11-04) on Linux plain and ASan
and on Windows plain. Not measured: the same module without a pass, macOS.

### `lsp` — editor-only target

`lsp: { os, mm }` tells the language server which target to judge against; `msc build` ignores it
entirely. `os` defaults to the host; `mm` resolves as a build's `--mm` does (`targetMemoryMode`:
`solana` ⇒ `manual`, `bare` ⇒ `manual` unless `mm` is given, else `drc`). Its one measurable
effect: when the effective mode is `manual` and the open file is not under `std/`, every async
site gets FREESTANDING E01 as a *warning* — measured (2026-09-06, real stdio LSP, when the key was
`gc`): `lsp = { os: "bare" }` → 3 warnings on a 3-async-site file; no `lsp` section, or
`gc: "drc"` → 0. A project that declares nothing keeps exactly the diagnostics it had. Unknown
`os`/`mm` values are reported when the editor opens `build.ms` itself (`validateBuildConfig`,
LSP-only); the old `gc` key is a field msc does not read and stops every command.

### Declared but not wired — do not rely on these yet

Measured 2026-09-22, card `~/metascript/.inbox/compiler/2026-09-22-build-ms-declared-but-unwired.md`:

- `resolve.alias` — wired for `msc build`, `msc check` and `msc run --target=raiser`, and the value is read relative to
  the importing file's directory, not the project root. Measured 2026-10-25 with `msc` v0.3.4
  (`~/.metascript/BUILD` binary `6b8655024`), entry `src/main.ms`: `"@lib": "../lib"` resolves
  to `<root>/lib` and `"./lib"` to `src/lib` under `msc build`; an alias used from
  `src/deep/m.ms` with `"../lib"` resolved to `src/lib`; an absolute path resolves;
  `"./src/lib"` stops with `Cannot resolve module` (also under the name `lib`). `msc run
  --target=raiser` resolves the same aliases (measured on a candidate built from this branch,
  2026-10-25: `deep:src-lib`). The same older record observed C/JS `msc run` failing to
  resolve `@lib/util`; that is a historical observation, not a current target restriction.
  A target-specific alias claim needs its exact importer/manifest consumer rechecked.
  Not reverified here: Windows paths, an alias target outside the project or all run targets.
- `root` was declared in `std/build`'s `BuildConfig` and read by nothing (measured 2026-10-15 on
  `7e7c0dd02`: `root: "src"` changed no resolution). It is gone from `BuildConfig` and refused as
  a field msc does not read.
- Importing a dep by its bare root (`import { greeting } from "greeter"`) fails; the subpath form
  `from "greeter/src/index"` works (see below).

`resolve.searchPaths` / `resolve.extensions` are not read and are refused.

## `build.ms` as a build graph

A `build.ms` whose exports are build nodes is a program, not a literal. Each exported node is a
command-line name (`msc build app`), and `export default` is what a bare `msc build` / `msc run`
take. The vocabulary is Zig's `std.Build` without the `add` prefix (`executable`, `library`,
`systemCommand`, `runArtifact`, `installArtifact`, `step`, `writeFiles`, `updateSourceFiles`,
`option`, `standardOptimizeOption`, `standardTargetOptions`), and a command keeps Zig's `add…Arg`
methods. The types are in `std/build/graph.ms`; the design and its decisions are in
`~/metascript/.inbox/compiler/2026-11-09-design-build-ms-typed-graph.md`. `msc init` writes the
two-line form:

```ms
import { executable, path } from "std/build";
export default executable({ entry: path("src/index.ms") });
```

Measured on 2026-11-10, a candidate of tree `97f6320958bf`, in a fresh `msc init` directory:
`msc build` printed `Built index → /tmp/bgdoc/out/index`, a second one `Up to date`, and `msc run`
printed `hello, metascript!`.

**Two phases.** Configure runs `build.ms` on Raiser and records the graph; it runs nothing. Every
host call that writes, spawns or reads the environment fails there, and `msc check`, `msc test`
and the editor configure only, so opening a project never runs its commands (a `systemCommand`
that touches a marker left no marker after `check`, `test` and `--list`). `msc build <node>` then
runs the nodes it needs with the user's full rights, `-j<n>` at once (one per cpu by default);
`--dry-run` prints every command line and runs none.

**A failed node.** The build keeps going, as `zig build` does: a failed node prints its own
`error:` line when it fails, every node that does not depend on it still runs, a node below it
never starts, and the build exits 1 after a summary of what did not succeed. `--summary=<mode>`
chooses what the end of the build lists: `failures` (the default: nothing when all is well),
`all` (every node with `success` or `reused`, its wall time and its peak memory), `new` (`all`
without the nodes taken from the store), `line` (the count only), `none`. Zig's words for
`reused` and `(shown above)` are `cached` and `(reused)`; `reused` here already means "taken
from the store". Measured 2026-11-12, candidate of tree `9c637f36f1e2`, where `after` reads
`bad`'s output and `good` and `worse` depend on nothing:

```
$ msc build --colors=off all
from-bad
error: bad: sh -c echo from-bad; exit 3 sh exited with 3, expected 0
error: worse: sh -c exit 4 sh exited with 4, expected 0
Build Summary: 1/5 steps succeeded (2 failed)
all transitive failure
+- bad failure
+- after transitive failure
|  +- bad (shown above)
+- worse failure
$ msc build --colors=off --summary=all fine
reused: said
Build Summary: 3/3 steps succeeded
fine success 0ms
+- good success 1s
+- said reused 53ms
```

On recompiler itself, same candidate, `msc build --summary=all tests` (the gate's tests lane as
ten nodes, 5645 tests passed, 777.8 s at host load 9 rising to 73) names each tier's wall time
and peak, and a second run reuses all of them in 5.6 s:

```
Build Summary: 12/12 steps succeeded
tests success 1ms
+- tests src/test/js/index.ms success 5m MaxRSS:3G
|  +- msc success 1m MaxRSS:5G
+- tests src/test/handoff/index.ms success 11m MaxRSS:3G
|  +- msc (shown above)
+- tests src/test/fmt/index.ms success 21s
|  +- msc (shown above)
+- tests src/test/c/index.ms --tests-shard=0/3 success 6m MaxRSS:3G
   +- msc (shown above)
```

(seven tiers between these cut). Not verified: Windows and macOS, a failure on recompiler's
own graph, `--summary` with `msc run <node>`.

**Paths.** `path("x")` resolves like Node's `path.resolve` against the directory of the file that
calls it, so a library's build function in another package names its own files. `glob("src/*.ms")`
lists the files under that directory, sorted, never entering a dot-directory, and entering only
the directories its pattern can match (`globReachesInto`, `std/fs/glob.ms`): the leading literal
segments bound the walk and a `**` opens everything below it. Measured 2026-11-13 on recompiler's
own `build.ms` at main `4a9e3de55090` (two globs, `tools/**/*.sh` and `tools/**/*.ms`), in a
worktree whose `out/` holds 88,764 directories, rtx at load 11, one candidate with the earlier walk
and one with the bounded walk: `msc build --list` 14.9 s → 1.1 s, `openat` calls under `strace -c`
180,482 → 1,438, the same listing; a no-change `msc build msc` 0.4–1.1 s at load 18. Before, each
glob walked the whole worktree and kept visited directories in a list.

**Options.** `option(name, description)` reads `-Dname=value` as text (a bare `-Dname` is
`"true"`) and is null when the command line does not name it. `option(name, description,
fallback)` has the fallback's type, `number`, `boolean` or `string`, and its value when the
command line is silent; text that is not of that type stops configure and names the option
(`shards: 'many' is not a number`, `fast: 'maybe' is not true or false`), and `--list` shows the
fallback. `--release`/`--danger` give `standardOptimizeOption()` ReleaseSafe/ReleaseFast, and
`--os`,
`--cpu`, `--abi` give `standardTargetOptions()`. An option the command line gives and `build.ms`
never asks for stops the build: `the command line gives the option 'nope', which build.ms does
not declare; it declares greeting, optimize`. `msc build --list` names each export and option:

```
app (default)  executable
table  command
-Dgreeting=…  the word the table starts with
-Doptimize=…  Debug, ReleaseSafe or ReleaseFast; --release and --danger name the last two
```

**Dependencies.** `import { lib } from "lib/build"` imports a dependency's build functions
through the same `deps` alias as source imports. A build function should take the consumer's
choices (`lib({ optimize })`), so one dependency can be built two ways in one graph. Two nodes
of the same shape (kind, inputs, arguments, dependencies) are one node, so calling `lib` twice with
the same arguments builds it once; the approved design memoised the call by its arguments, and
merging by shape gives that result without intercepting calls (`keepOne`,
`src/compiler/build/configure.ms`). An executable or library no export names is written to
`out/.graph/<entry>-<shape hash>`, so two configurations never share a file.

**Reuse.**
- The graph is cached in `out/.configure.json`, keyed by the compiler and the `-D` options, and
  reused while every file the evaluation loaded hashes the same and every `glob` lists the same
  files. Measured 2026-11-09 on a candidate of `01744ec89`, host load 60–150:
  configure 1.57 s, cached 0.008 s. A graph whose plan runs a `step` with `make` configures
  again, because the closure lives in the VM; a `step({ description, inputs })` without `make`
  only groups its inputs and runs from the cached graph.
- A command or `writeFiles` output lives in the global store under `build/o/<digest>` and is
  reused while its tool, arguments and input content are the same ([BUILD-CACHE.md](BUILD-CACHE.md)
  "What a worktree reuses from another"); `--dry-run` prints `reused:` for each. Input hashes are
  remembered by change stamp, so an unchanged input tree is not read again: a command over 400
  files of 256 KB took 0.96 s to find its output before and 0.006 s after (tree `7d6a63e19c01`,
  host load 16–18, three runs each).
- An executable node is looked up in the store before `msc build` runs (`runCompile`,
  `src/compiler/build/execute.ms`): its key is the compiler, the flags and the project root, and
  its manifest lists every file the build read, which `msc build --depfile=<path>` writes from
  the project record (`writeProjectDepFile`, `src/compiler/cache.ms`). A manifest keeps up to
  16 input states (`MANIFEST_ENTRIES`, `store.ms`), so a tree back at an earlier state (a
  revert, a branch switch) gets that state's binary copied to `out/<name>` instead of a build.
  Measured 2026-11-12 on recompiler's own `build.ms`, candidate of tree `d74493c1a6e2`, rtx at
  load 1.5–2.3, one run each: `msc build msc` after a one-line compiler edit 37.0 s, back at the
  previous state 2.5 s, forward again 1.9 s, no change 1.9 s; before this layer the return took
  53.3 s, the same as the edit. ccache's manifest is the model; Zig keeps one state per step, so
  a revert misses there. Not verified: a library node, a cross-compiled target, Windows.
  Limits: the key holds the project root, because two checkouts of one tree do not build the
  same bytes ([BUILD-CACHE.md](BUILD-CACHE.md) "Two checkouts of the compiler"); the project
  record's header-presence queries are not in the manifest, so a new header that shadows an old
  one is seen only when `msc build` itself runs; each state keeps one copy of the binary until
  the store's age sweep.
- `updateSourceFiles` writes a generated file into the source tree only when its content changed.

**Commands, checks and runs** follow Zig's `Run` step (`hasSideEffects`, `Step.writeManifest`):
- `systemCommand(argv, options)` and `runArtifact(app, args, options)` take in one call what the
  methods below set one by one. An element of `argv` is text, a `path()` or an executable node;
  the last two are passed as their file and make the command depend on it, as `addFileArg` and
  `addArtifactArg` do. `options` is `{ env, cwd, inputs, expectExitCode, description, maxRss }`,
  each field doing what `setEnvironmentVariable`, `setCwd`, `addFileInput`, `expectExitCode`,
  `describe` and the `maxRss` field do: a node written each way is one node in the graph. A
  value in `env` (and the value `setEnvironmentVariable` takes) can also be a path or an
  executable node; the command then depends on it and runs again when its content changes. Zig's
  environment values are text only. `--dry-run` and a failure print the command with its
  environment. Measured 2026-11-12 on rtx, candidate of tree `6e5190f123f4`, with `tool` printing
  `tool ran`:

  ```ms
  const shards = option("shards", "how many runners", 2);
  const fast = option("fast", "skip the slow part", false);
  export const tool = executable({ entry: path("src/tool.ms") });
  export const same = systemCommand(["cmp", path("note.txt"), path("note.txt")], { expectExitCode: 0 });
  export const ran = runArtifact(tool, ["--quiet"], { cwd: path("src"), expectExitCode: 0 });
  export const viaEnv = systemCommand(["sh", "-c", "\"$TOOL\"; cat \"$NOTE\"; echo $MODE"], {
  	env: { TOOL: tool, NOTE: path("note.txt"), MODE: `${shards} shards, ${fast ? "fast" : "full"}` },
  });
  export const all = step({ description: "all", inputs: [same, ran, viaEnv] });
  ```

  ```
  $ msc build --colors=off --list
  tool  executable
  same  command
  ran  command
  viaEnv  command
  all  all
  -Dshards=…  how many runners (default 2)
  -Dfast=…  skip the slow part (default false)
  $ msc build --colors=off -j1 --summary=all all
  Built 13 module(s) → /tmp/claude-1000/probe/doc/out/tool
  tool ran
  tool ran
  note
  2 shards, full
  Build Summary: 5/5 steps succeeded
  all success 0ms
  +- same success 2ms
  +- ran success 0ms
  |  +- tool success 4s MaxRSS:381M
  +- viaEnv success 5ms
     +- tool (shown above)
  $ msc build --colors=off -Dshards=5 -Dfast viaEnv
  tool ran
  note
  5 shards, fast
  reused: tool
  $ msc build --colors=off --dry-run -Dshards=5 viaEnv
  (cd /tmp/claude-1000/probe/doc && TOOL=/tmp/claude-1000/probe/doc/out/tool NOTE=/tmp/claude-1000/probe/doc/note.txt MODE=5 shards, full sh -c "$TOOL"; cat "$NOTE"; echo $MODE)
  $ msc build --colors=off -Dshards=many all
  error: /tmp/claude-1000/probe/doc/build.ms: unhandled exception: shards: 'many' is not a number
  $ msc build --colors=off -Dfast=maybe all
  error: /tmp/claude-1000/probe/doc/build.ms: unhandled exception: fast: 'maybe' is not true or false
  ```

  Pinned by 19 cases, red on the candidate before the change and green on this one (104 of 104,
  129–175 s), in `src/test/projectConfigCommands.ms`. Recompiler's own `build.ms` is written this
  way: `msc build --summary=all fixpoint` (`systemCommand(["cmp", stage2, stage3], {
  expectExitCode: 0 })`) gave 4/4 in 134 s at host load 37 falling to 15 and a second run reused
  all four in 1 s; `msc build lsp` (`env: { MSC: msc }`) ran its 69 scenarios green in 56 s.
  Limits: `addArgs` and the `args` of `runArtifact` take `string[]` only, because array elements
  are invariant ([LANG.md](LANG.md) "Elements are invariant"); `systemCommand` accepts a
  `string[]` variable as well as a mixed list. On Windows a command's `env` is
  the builder's own environment (`envPairs` of `std/process`) with the node's variables set over
  it, an inherited variable of the same name in another case replaced, passed through `spawn`;
  elsewhere it is set through `/usr/bin/env`. On d87, 2026-11-14, the `env` pins of
  `src/test/projectConfigCommands.ms` pass (`Build Summary: 3/3 steps succeeded`, `--dry-run`
  ends `MODE=x true)`), where the builder before answered `error: moded: setEnvironmentVariable
  is not supported on Windows yet`. A command past its `timeout`
  on Windows has only itself killed, as a Node `subprocess.kill()` does there (`ran past its
  timeout of 500 ms; it was killed, and the processes it started were not`, d87, the same day);
  elsewhere its process group dies with it. Not verified: macOS.
- A command with no output file, no captured stdout and no check runs every time, streams its
  output and gets no stdin; `hasSideEffects = true` makes any command run every time.
- `expectExitCode(n)` makes the command a check: it is reused only after it passed, and a failure
  prints `exited with 3, expected 0` and runs again next time. Its key holds the content of every
  artifact and `addFileInput` it names, so editing one input reruns it and reverting reuses it.
- `expectStdOutEqual(bytes)` and `expectStdErrEqual(bytes)` compare a stream byte for byte, as
  Zig's `Run` checks do (`Run.zig` `expectStdOutEqual`, `expect_stdout_exact` at 738d2be9d):
  the stdout one also expects exit code 0 unless a code was named, the stderr one leaves the
  exit code alone, so `echo careful >&2; exit 4` with `expectStdErrEqual("careful\n")` passes.
  `expectStdOutMatch(text)` / `expectStdErrMatch(text)` are Zig's `expect_stdout_match` /
  `expect_stderr_match`, which Zig reaches through `addCheck` only. A failure prints Zig's
  frame (`========= expected this stdout: =========`, the bytes, `========= but found:
  ====================`, the stream); a checked stream is not printed when the check passes.
  Measured 2026-11-12, candidate of tree `55d4b0200539`, in
  `src/test/projectConfigCommands.ms` (the `expectStd…` cases, red before the executor read
  the checks).
- `test({ entry })` is Zig's `addTest` as one check: a command running `msc test <entry>
  --depfile=…` (`test`, `std/build/graph.ms`), keyed by the files the test build read
  (`writeBuildDepFile`, `src/compiler/cache.ms`: the modules, link inputs, `build.ms`, the C
  sources and headers, the C compiler). It runs again when one of them changed, is reused when
  an unrelated file did, and a failure is never kept. It knows what the test **build** read, not
  what a test reads while it **runs**: name fixtures with `addFileInput(path("fixtures"))` on
  the command `test()` returns. Recompiler's own tiers read `std/` and `runtime/` while they
  run, so `build.ms` gives them the whole trees as inputs. Measured 2026-11-12, candidate of
  tree `f34bdc617978`: the case "a test node runs again only when a module its entry imports
  changed" gives `ran|reused|failed|failed|reused|ran|reused`; recompiler's `msc build tests`
  (the gate's tests lane as ten nodes) ran 5645 tests in 402.3 s at host load 55–60 and a
  second run reused all ten in 4.0 s. Not verified: `--target=js`, Windows.
- A depfile input that changed after its job started keeps the output out of the store, because
  its hash would vouch for content the job may not have read (`readSetUnchangedSinceStart`,
  `execute.ms`); before, a command that appended to its own input was reused on the next run.
  A command that declares a depfile and does not write one fails with `did not write its
  depfile copy.d`, as Zig's `Run` does (`try man.addDepFilePost`, `Run.zig` at 738d2be9d).
- `runArtifact(app, args)` is a command whose program is `app`; `addArtifactArg(app)` and
  `addPrefixedArtifactArg("--msc=", app)` pass an artifact's path and key the command by its
  content; `getEmittedBin()` names the binary as a file argument.
- `msc build <node> -- a b` appends `a b` to that node's command only (Zig `b.args`); in file
  mode the arguments after `--` are an error.
- `executable({ lto: LtoMode.None, compiler: stage1 })` builds with `--lto=off` and with the graph's
  `stage1` binary as the compiler (Zig `Compile.lto`, Rust bootstrap stages); `mscExe()` names the
  `msc` running the build (Zig `b.graph.zig_exe`).

- `node.maxRss = 600e6` (or `executable({ maxRss })`) declares a node's memory bound, as Zig's
  `max_rss`. `--maxrss=<size>` (`8G`, `512Mi`) caps the build, by default at `totalMem()`. A node
  above the cap stops the build before anything runs (`huge: declares maxRss 953674316406 MiB,
  above the 1000 bytes this build may use (--maxrss)`); nodes whose bounds together pass it run one
  after the other; a command whose peak passes its own bound fails (`greedy: sh -c … peaked at 193 MiB, above
  its declared maxRss of 19 MiB`). The peak is `ChildProcess.peakRss()`: `ru_maxrss` on POSIX,
  `PeakWorkingSetSize` on Windows (compiled and linked with zig for x86_64-windows-gnu, not run).
  On Linux a child's `ru_maxrss` starts from the peak of the process that spawned it (measured
  2026-11-12 on rtx: a C parent holding 300 MiB spawns `true` and reads 307724 KiB for it,
  under `fork` and `vfork` alike), so a peak no higher than `msc`'s own at the spawn reads as
  unknown: the summary names no `MaxRSS` for it and a `maxRss` bound below `msc`'s own size
  (20–170 MB in these runs) is not enforced. Before, `true` with `maxRss = 20e6` failed as
  `peaked at 20 MiB`. Not verified: whether macOS inherits the same way.

Each of these is pinned in `src/test/projectConfigCommands.ms` (59 tests, candidate of tree
`f8042fd5e`, rtx, 2026-11-10). A draft recompiler `build.ms` measured on a candidate of `b009bd13a`: `msc`
84 s then `Up to date` in 2.4 s; `stage2` built by `out/msc` in 68 s; `corpus` against `out/msc`;
`test -- src/utils/color.ms --tests-in-dir` reran after an edit to `color.ms` and was reused after
the revert. Not verified: Windows and macOS, a check over a whole suite.

### Recompiler's gate lanes as nodes

Recompiler's root `build.ms` declares one log-producing node per land-gate lane (`lanes`, selected
by `-Dlanes=`, tested compiler `-Dsubject=`, time limit `-DlaneLimit=`), the reruns of a new red
(`reruns`, `-Drerun=`, `-DrerunBase=`) and the verdict (`gate`, `tools/gate.ms`). `tools/gate.sh`
still gates every land; these nodes run beside it. What the code cannot say, measured on rtx,
2026-11-13, builder `fca3f0a80cc6`:

- **A lane node never fails; its log ends `SECS= RC= END`.** A node that fails stores no output, so
  a red lane would leave the verdict nothing to read. The time limit therefore lives in the lane's
  wrapper, which polls as `tools/gate.sh` `bounded` does, kills the process group (on Windows
  each of its process trees first, `taskkill //T //F`, as `kill_group`) and writes `TIMEOUT after
  Ns, process tree killed`; the node's own `timeout` is a backstop 60 s later. `-Dlanes=lsp
  -DlaneLimit=3`, 2026-11-14: on rtx `TIMEOUT after 3s, process tree killed`, `SECS=3`, `RC=137`,
  no compiler process left; on d87 the same three lines. Without the limit the lane ran 55 s on
  rtx (`RC=0`) and 110 s and 134 s on d87 (69 of 69, then 68 with `a module the second build.ms
  global import reaches sees the first one only` timing out after 10 s).
- **The reruns are a second build, not work inside the verdict tool**, because `std/process` refuses
  `ownProcessGroup` on Windows and a rerun made by the tool could not kill a hung process tree there.
  `tools/gate.ms --rerun-with=<msc>` reads the changed paths from git, plans, runs
  `msc build -Drerun=… -DrerunBase=<merge base> reruns` and judges both sides' logs. Tree
  `a5471a26e199` with a bug seeded in `src/lexer/chars.ms`, load 26 to 52: 94 s including main's
  candidate, `tests · 8 red · 7 new · 1 not the slice's`. Not run for real: the corpus, san, tsan,
  guard, hcr, lsp and suite rerun commands.
- **Main's side is built in `out/gate-main` of the gating checkout**, a worktree of the merge base
  that runs the same `reruns` build. Rejected: one candidate of main shared by every gate on the host
  under a lock, as `gate.sh` keeps in `~/.metascript/gate-main/<tree>`, because `std/fs` has no file
  lock; the cost is one build of main's candidate per gate that reruns anything.
- **The tsan lane takes the san lane's log as an input**, because it reads the `out/corpus/threaded.txt`
  that san run wrote for the same compiler and selection. A checkout of `a5471a26e199` with this
  `build.ms`, `MSCORPUS_ONLY=400-actorHeapStr,401-actorSharedActorField msc build -Dlanes=san,tsan lanes`:
  with the edge, san `2 pass`, then tsan `2 pass`; without it they start together and tsan ends
  `✗ TSan lane: no out/corpus/threaded.txt`, `RC=1`. No other order is declared: `gate.sh` runs its
  lanes in phases (`PHASES`) and stops later phases on a new red, which is the driver's policy.
  Rejected: chaining the phases through their logs, because a log differs on every run and one
  edited shell script would then rerun the corpus.
- **The bundler-plugin check runs against bundlers a node installs into its output directory**
  (`npm ci` on a staged copy of `tools/bundler-plugin/harness`), where `gate.sh` installs into the
  checkout. A checkout of `a5471a26e199` with these nodes: the install `added 88 packages in 539ms`,
  the check 33 s at load 6 (45 to 100 s at load 39), native `188` of `188`; a second run reuses all
  three nodes in under 1 s; an edit of `vite.d.ts` reruns the self-test and the check and reuses
  the install. The consumer cells gave 6 of 7 on rtx, `rollup-watch-established` being red with
  `gate.sh`'s own layout too (8 of 8 runs). The check still links `tools/bundler-plugin/node_modules`
  (ignored) to that directory, because the adapters resolve bare imports from their own directory.
  It runs after `test.test.mjs`, whose self-test executes `gate.sh`'s `run_tools_lane` in the
  checkout and rewrites that link: run together, the check failed once with
  `Cannot find package 'magic-string'`.
- **The suite and tier nodes declare `maxRss`** (8e9 and 6e9), which admits them by RAM in place of
  `gate.sh`'s `TEST_JOB_KB` estimate of 3.5 GB. Tree `9d23d79b32ed`, 16 cores,
  `msc build --summary=all -Dlanes=suite,tests lanes`, 687 s, every `RC=0`:

  ```
  +- lane suite success 8m MaxRSS:5G
  +- lane tests.js success 3m MaxRSS:3G
  +- lane tests.handoff success 10m MaxRSS:4G
  +- lane tests.lang success 3m MaxRSS:4G
  +- lane tests.fmt success 21s MaxRSS:700M
  +- lane tests.c0 success 7m MaxRSS:4G
  ```

  (`checker3pass` and `helpers` 3G, `c1` and `c2` 4G, `crypto` none.) The summary rounds a peak down
  to the gigabyte, so the bounds leave at least 20 percent over the real peak; a tier that grows past
  its bound fails as `peaked at …, above its declared maxRss`, and the bound is then measured again.
  `-Dlanes=tests --maxrss=5G` stops before anything runs: `lane tests.js: declares maxRss 5722 MiB,
  above the 4768 MiB this build may use`. The bound covers a node's largest process (`ru_maxrss`),
  so it says nothing for a lane that runs many compilers at once (corpus, san, guard), and the cap
  is the host's total RAM, not what other gates on the host leave free, which is what `gate.sh`
  reads from `MemAvailable`.

- **The solana replays report missing modules as one red, and the modules' lockfile is one of their
  inputs.** `tools/solana/node_modules` is untracked: a gate checkout and a worktree are given a copy,
  a bare copy of the tree has none. Tree `b4b6da6bdc5`, 2026-11-15, `msc build -Dlanes=solana lanes`
  then `tools/gate.ms`, three times in one directory: without the modules, 109 s,
  `solana · 1 red · 0 known · 1 new`, `new: replay-deps` (the line `gate.sh` prints; before, the same
  state gave 15 reds, one `Cannot find package '@solana/kit'` per replay); with them copied in, 4 s,
  `0 red`, the replays ran and every program build was reused; removed again, 1 s, the first run's red
  log reused. A lane log that records a red is a node that succeeded, so it is reused until an input
  changes: without `tools/solana/node_modules/.package-lock.json` among the inputs, the run after the
  copy ended in 3 s with the same `replay-deps` red. A path that does not exist is accepted as an
  input and changes the node's key when it appears.
- **The builder is a copy of the installed compiler placed in the tree**, as a gate checkout has
  (`./msc`), because a compiler reads the std beside it and `src/` may import std newer than the last
  sync. Tree `b4b6da6bdc5` with the installed `2e3db04cfb2` run from its own directory:
  `Cannot resolve module 'std/process/native'`, `0/63 steps succeeded`; the same binary copied into
  the tree built the candidate and ran the lane above.

- **`GATE_GRAPH_LANES="boundary cache corpus fmt guard hcr lsp san solana suite tests tsan"` makes
  `tools/gate.sh` run those lanes as these nodes**: the gate's builder runs `msc build -Dlanes=<lane> -Dsubject=<candidate>
  -DlaneLimit=<limit> lanes`, the node logs one after another are the lane log, and a node's `RC` is
  the lane's. Unset, the gate is unchanged; a lane named there that has no such run stops the gate
  with an error that names it. Each pair below is two fresh checkouts of one tree on rtx, 2026-11-15,
  `GATE_TRIAGE=0`, the second with the variable:

  ```
  0c693544f49, --lanes build,boundary,fmt,lsp
  direct   boundary 9m33s · 0 red   lsp 0m42s · 0 red   RED (build, boundary, fmt, lsp) 11m55s
  graph    boundary 8m10s · 0 red   lsp 0m46s · 0 red   RED (build, boundary, fmt, lsp) 10m41s
  da60cc67cf1, --lanes build,fmt,cache, both at once
  direct   cache 9m02s · 0 red   fmt 3m19s · 1 red · 1 new: std/crypto/tls/aead.ms   RED 11m43s
  graph    cache 9m03s · 0 red   fmt 3m25s · 1 red · 1 new: std/crypto/tls/aead.ms   RED 11m46s
  10cd8e11206, --lanes build,hcr, both at once
  direct   hcr 16m01s · 4 red: hcrStepCrash, hcrStepJoinCrash, hcrStepSpareCrash, hcrWatchOwnOutput   RED 18m49s
  graph    hcr 16m04s · 3 red: hcrStepCrash, hcrStepJoinCrash, hcrStepSpareCrash                      RED 18m50s
  50a00a8f25b, --lanes build,solana, then --lanes guard three times, both at once
  direct   solana 2m31s · 0 red   guard 3m39s · 10 red · 1 known   3m01s · 9 red · 1 known   2m38s · 9 red · 1 known
  graph    solana 0m28s · 0 red   guard 3m34s ·  9 red · 1 known   2m02s · 9 red · 1 known   1m58s · 9 red · 1 known
  636ad6ef5e7, --lanes build,suite,tests, one run after the other, GATE_PAR=8
  direct   suite 6m23s · 0 red · 6213/6213   tests 10m16s · 0 red · 6046/6046   GREEN 12m49s   least RAM available 47 GB
  graph    suite 6m25s · 0 red · 6213/6213   tests 10m22s · 0 red · 6046/6046   GREEN 12m53s   least RAM available 44 GB
  7c402948632, a land-form gate with --programs naming three programs, both at once
  direct   corpus on 3 program(s) 0m07s · 0 red · 15/15   san on 3 program(s) 0m05s · 0 red · 3/3   GREEN 7m50s
  graph    corpus on 3 program(s) 0m11s · 0 red · 15/15   san on 3 program(s) 0m07s · 0 red · 3/3   GREEN 7m52s
  7c402948632, --lanes build,corpus,san,tsan, both at once: corpus has a new red, so san and tsan are skipped
  direct   corpus 35m36s · 9 red · 4 known · 5 new · 12513/12522   RED 38m27s
  graph    corpus 35m39s · 8 red · 4 known · 4 new · 12515/12523   RED 38m27s
  7c402948632, --lanes build,san,tsan with the gate's triage on, both at once
  direct   san 16m01s · 2 red · 1 known · 1 not the slice's · 2675/2677   tsan 3m11s · 0 red · 279/279   GREEN 23m18s
  graph    san 16m10s · 2 red · 1 known · 1 not the slice's · 2675/2677   tsan 3m11s · 0 red · 279/279   GREEN 23m36s
  ```

  The corpus lanes take the gate's narrowing as `-DcorpusOnly=<programs>` (the node's
  `MSCORPUS_ONLY`) and the corpus lane its raiser cells as `-DcorpusRaiser=<0|1>`; the runner is the
  graph's own `corpusRunner`, so the gate builds none for a lane named in the variable. The four new
  corpus reds both runs name are main's (`derivedClassArgumentIsOneInstance [c]` and `[danger]`,
  `plainObjectTrait [esm]` and `[js]`); the fifth of the direct run is `tlsTransport [c]`, a failed
  local connect beside the second corpus run (card
  `2026-11-15-corpus-tlstransport-c-was-red-once-beside-a-second-corpus-run.md`). The tsan lane read
  the program list the san node wrote in both. An earlier san pair without triage also agreed on the
  second run (2 red, the same names), the direct first run having `httpServeConcurrentStops [san]`
  red once more. Not run: a corpus lane with the raiser cells through `gate.sh`.

  The suite and the tests lane keep `gate.sh`'s own driver (`run_test_lane`): it starts another tier
  only while `MemAvailable` holds one more, and runs a part killed with 137 or 143 once again. Through
  the graph each part is one build of one node, which `-Dlanes` names in full
  (`-Dlanes=tests.js`, `-Dlanes=tests.c1`; `-DtestShards=<n>` is the gate's shard count of the C tier,
  and 1 gives one node `tests.c` without `--tests-shard`), and the second run of a killed part uses
  the run name `<run>.again`, because the first log is a node that succeeded. Not run: a part killed
  for real inside a gate (`graph_lane_self_test` pins the second run's name with a stand-in).

  A lane's wrapper kills what is left of the lane's process group once its leader has ended, so the
  `SECS`, `RC`, `END` lines are the last of a log. Before, a lane whose leader was killed left its
  children writing after them: under a RAM shortage on rtx, 2026-11-15T03:39, earlyoom ended
  `msc test` of the suite, and the stored log had `RC=143` at line 7223 of 10778 with the test
  binary's output after it. A subject that prints `early`, starts a child that prints `late` after
  4 s and ends itself with `TERM`, as the lsp lane's subject:

  ```
  before   build exit 0 in 5 s   early · SECS=0 RC=143 END · late
  after    build exit 0 in 1 s   early · SECS=1 RC=143 END
  ```

  The same nine guards are red in all six guard runs (main's reds, each with a card); the tenth of
  the first direct run is `actorChurnReap [drc]`, a flake under load with a card, and an earlier
  direct run of that tree also had `rcFamilyMismatchAborts [drc]` red once. The guard lane takes its
  shard count from the gate (`-DguardShards`) and splits by fixed shards, where `gate.sh` lets its
  runners claim guards from one list. The solana lane runs its host tests at once (the direct lane
  one after another) and leaves the on-chain programs and replays out (`-DsolanaReplays=0`) unless
  the gate's own rule asks for them (`--release`, or a path under `tools/solana` or
  `runtime/freestanding`); a gate with that rule true was not run through the graph.

  The three hcr reds both runs name are the ones a card records as failing under `run-remote.sh` and in no
  land gate, and `hcrWatchOwnOutput` is red now and then on Linux in either way of running the
  lane (it was red through the graph and green direct on 2026-11-15T03:20); each has its card. The
  hcr lane takes its shard count from the gate (`-DhcrShards`), and a shard that ends non-zero
  without a `FAIL` line is named as `gate.sh` names it, `FAIL hcr shard <i>/<n>: exit <rc> with
  no named failure`.

  The red of the first pair is fmt, the formatter's crash on main (`fmt: exit 1 with no named
  failure` in both); the second pair's checkouts drop the crashing line's type annotation, and both
  runs then name the same `LOSSY` file. The fmt lane is two nodes, as in `gate.sh`: the candidate
  builds `src/test/fmt/run.ms` into the node's own output (`fmt.runner`), and `fmt` runs that file,
  because `msc run` would link the shared `out/debug/run` beside other lanes (`runner_self_test`).
  Not run through `gate.sh`: every lane whose selection `gate.sh` passes by environment or path
  (tools), and the tier selection of a gate without `--lanes` (`tier_select`). A second `gate.sh` run in one checkout,
  or in a fresh clone at a path where the same tree was built before, went red at build before any
  lane (`self-host: gen1 wrote no link response file and gen2 differs from it`: the candidate's link
  is restored from the cache), so each run of a pair needs a path of its own.

- **`-DlaneRun=<name>` names a run of the lanes, and `tools/gate.sh` gives every gate its own**, so
  a gate never reads the lane log of an earlier one: a log, red or green, is a node that succeeded,
  and the lanes declare only `src`, `std` and `runtime` as inputs. Unset, a log is reused by any
  build with the same inputs, which is what the edit loop wants. `-Dlanes=lsp` on rtx, 2026-11-15,
  tree `99377421f47`, one directory:

  ```
  subject the builder:   run a 46 s RC=0 · run a again 0 s, reused · run b 34 s RC=0 · no name 35 s · no name again 0 s, reused
  subject /bin/false:    run a 1 s RC=1 · run a again 0 s, reused · run b 1 s RC=1, ran again
  ```

Not verified: every lane in one build on one host with a verdict that matches `gate.sh` (one run,
2026-11-15, did not: card `2026-11-13-gate-through-the-build-graph-remaining-steps.md`), macOS, any lane
but lsp on Windows, and a real land gated by these nodes.

## Packages

A package is a directory with a `build.ms` carrying a `package` block. `name` and `version` are
what identity is made of; the rest is registry metadata shown by `msc publish`.

- **name**: `[a-z][a-z0-9-]*(/[a-z][a-z0-9-]*)?` — lowercase, optional single slash for scope.
- **version**: `<major>.<minor>.<patch>[-prerelease]`. No `v` prefix, no leading zeros.

### Dependency sources

| `deps` value | Meaning | Lockfile |
|---|---|---|
| `"file:../libpkg"` | local folder, relative to the project root or absolute | none — `build.ms` is the whole truth |
| `"1.2.3"` | registry, **exact minimum version** | `msc.lock` |
| `"git:github.com/owner/repo@v1.2.3"` | not supported yet: `msc add` and `msc install` refuse it | — |

There are no range operators — `^`, `~`, `>=`, `*` are errors, by design. A registry dep resolves
the version `msc.lock` names for it and nothing else: there is no Maximum Version Selection, and
`build.ms` is not compared with the lock (measured with a candidate built from `e5ab88ef3`:
`build.ms` naming `2.0.0` against a lock entry `1.0.0` imported the cached `1.0.0`). A registry
package's own dependencies are not installed; `msc install` refuses an entry that needs one:

```
$ msc install        # msc.lock: probeOuter@1.0.0 with deps { probeInner: 0.1.0 }, no probeInner entry
error: probeOuter@1.0.0 needs probeInner@0.1.0; transitive dependencies are not installed yet
1 missing, 0 OK      # exit 1
```

`devDeps` are for tests and tooling; both are compiled and both may declare commands.

### Importing a dependency

Every dependency becomes an import alias bound to its folder (`depRoots`, `src/compiler/compile.ms`),
so source imports it by name plus subpath:

```ms
import { greeting } from "greeter/src/index";
```

`file:` deps are followed transitively (a dep's own `build.ms` `deps`/`devDeps` are read, depth
capped at 20). Registry deps resolve through `msc.lock` to `~/.metascript/cache/extracted/<name>@<version>/`. A git
entry resolves to `cache/extracted/<url>@<commit>/` only when it carries a `commit`; no command writes
one or fills that directory.

### `msc.lock`

Plain JSON, written by `msc add` for registry sources, read by every build. `file:` deps
never appear in it — moving the folder is the upgrade. Reader/writer: `src/compiler/package/lockfile.ms`.

`msc install` fails (exit 1, naming the dep) when `msc.lock` holds a git entry, when a registry
entry needs a package with no entry of its own, when `build.ms` names a registry or git dep
and `msc.lock` is missing or unreadable, and when a valid `msc.lock` has no entry for a dep of
`deps` or `devDeps` (measured with the same candidate, and for the last case with a candidate
built from `dcfa369ab`):

```
error: foo@git:github.com/acme/foo@v1.2.3: git sources are not installed yet
error: msc.lock not found, so registry and git deps cannot be installed
error: outer is in build.ms but msc.lock has no entry for it; run `msc add outer@1.0.0`
```

The last line is the output for `outer` in either section, exit 1. A git dep with no lock entry
prints `error: foo: git sources are not installed yet`, because `msc add` refuses git too.

`msc add foo@git:github.com/acme/foo@v1.2.3` (also with `-D`) prints
`error: git sources are not installed yet` and leaves `build.ms` and `msc.lock` unchanged.

## Declared commands — `package.bin`

A package exposes a command by naming it in `package.bin`: key = what the consumer types,
value = a `.ms` entry relative to the package root. A command is always MetaScript source — never
a binary built at install time, never a binary committed to the package.

```ms
package: {
	name: "greeter",
	version: "1.0.0",
	bin: {
		"greet": "tooling/cli.ms",
	},
},
```

A command name is lowercase letters, digits and `-`, starting with a letter. Two gates fail loud
and install no command (both measured, exit 1):

```text
$ msc add rival@file:../rival
added rival → file:../rival
error: greet is declared by both greeter and rival
no command was installed

$ msc add badcmd@file:../badcmd
error: badcmd: command 'build': shadows the msc subcommand of the same name
no command was installed
```

A name colliding with an `msc` subcommand is refused at `publish` and again at install
(`RESERVED_COMMANDS`, `src/compiler/package/bin.ms`); the entry must be a relative `.ms` path
inside the package and must exist.

**The dep stays when the command is refused.** `msc add rival` above writes `rival` into
`build.ms` first, then refuses to install the colliding command — the dependency is the thing
you asked for, the command is a derived effect, and the refusal names both claimants so you can
drop one or address it as `msc x <package>:greet`. Rolling the dep back would undo the requested
operation to save you from a side effect you were just told about.

### Running one — `msc x`

`msc x <command> [args…]` resolves the command against the project's own `package.bin`, then
every dependency the project can see (`file:` deps, `msc.lock`, then the global manifest), and
runs the entry on Raiser from source. The project's own commands get no shim in `.msc/bin`.
**Everything after the command name belongs to the command**, including flags — `msc x greet
--release` passes `--release` to `greet`. The command's `argv` is `[<command name as declared>, …args]`
and its exit status is the exit status of `msc x`.

- `msc x` with no argument lists the declared commands.
- Two packages declaring one name is not an error until you run it: `msc x greeter:greet` picks one.
- Nothing is built or cached: there is no binary under `~/.metascript/cache/bin/`, and a `file:`
  dependency's edits show on the next run.

Measured end to end (2026-09-22, clean scratch consumer): `msc x greet Son` → `hello v1, Son`;
after changing the package to 2.0.0 with different output, the same invocation prints the new
output with no reinstall.

### Shims — running one by name

`msc add` and `msc install` write one shim per declared command into `<project>/.msc/bin/`,
listing what landed:

```text
$ msc add greeter@file:../greeter
added greeter → file:../greeter
  greet (greeter)
1 command(s) installed in …/.msc/bin

$ cat .msc/bin/greet
#!/bin/sh
# msc shim v1
exec msc x 'greeter:greet' "$@"
```

The shim names the package and the command, **never the version** — an upgrade rewrites
`msc.lock` (or the `file:` target moves) and the same shim keeps resolving. Measured: shim
SHA-256 identical before and after a 1.0.0 → 2.0.0 bump that changed output. On Windows the shim
is `<command>.cmd` holding `@msc x <pkg>:<cmd> %*`.

**A file that is not an msc shim is never overwritten** — it is left alone, reported, and the
install exits 1. Recognition is by the `# msc shim v1` / `rem msc shim v1` marker line (the
pre-marker formats are still recognised); a hand-written wrapper that merely mentions `msc x`
is foreign. Measured: a wrapper containing the words `msc x` survived `msc add` untouched.

Shims are pruned by the same sync that writes them: `msc remove` (or a package renaming its
command) leaves no stale shim behind — measured: `msc remove greeter` prints
`pruned 1 stale command(s) from …/.msc/bin`.

Global install is explicit: `msc install -g greeter@file:../greeter` adds the package to
`~/.metascript/global/build.ms` and writes the shim into `~/.metascript/bin/`, beside `msc` and
already on `PATH`. `msc add` never touches the global namespace, and `msc remove -g greeter`
undoes a global install — manifest entry and shim both (measured).

### Trust boundary — what runs when

**Installing runs no package code.** `msc add`/`install` parse `build.ms` with the compiler's
own AST parser and write files; there are no lifecycle scripts and nothing executes. This is
deliberate — install-time execution is the top malware vector in npm-land, and the design keeps
it structurally impossible.

**Building runs package compile-time code, but cached dependencies are restricted.** Macros,
decorators and `@comptime` blocks whose canonical source path is under `~/.metascript/cache/`
run with only pure host bridges and read-only filesystem bridges. File mutation, process and
environment access, execution, standard I/O, clocks, archive handles, and every new or
unclassified host bridge fail loud at `CallHost`. The capability default and dispatcher gate
live in `src/raiser/hostRegistry.ms` and `src/raiser/vm.ms`; the cache-path boundary and
per-invocation policy live in `src/compiler/meta/hostPolicy.ms`; `hostTable.ms` is the explicit
allowlist.

This is an integrity and execution boundary, **not a confidentiality boundary**: cached macro
code may read any file the compiler user can read. Project-local code, `file:` dependencies and
the compiler's own standard library are outside the cache boundary and retain full host access.
After compilation, the package command itself also runs with the user's normal permissions.
`msc.lock` records a registry archive's integrity hash. `msc add` and `msc install` check it when
they download the archive and refuse a missing or mismatched one; a build reads the extracted
cache directory without hashing it again (see Verified below). Checked once is not audited.

## Command reference

| Command | Behavior |
|---|---|
| `msc init <name>` | Scaffold the two-line graph `build.ms` (`export default executable({ entry: path("src/index.ms") })`) and `src/index.ms` ending in a bare `main();`, so `msc build` / `msc run` take the project without a file argument. Measured 2026-11-10 on a candidate of tree `97f6320958bf`: `msc build` printed `Built index → <dir>/out/index`, `msc run` printed `hello, metascript!`. |
| `msc add <spec> [-D]` | Add a dep to `deps` (or `devDeps` with `-D`) in `build.ms`, then install commands. Spec: `name` (registry latest), `name@1.2.3`, `name@file:path`; a `git:` source is refused. Also rewrites `msc.lock` for registry. |
| `msc remove <name>` | Remove the dep from `build.ms` + `msc.lock`, then prune its shims from `.msc/bin/`. `-g <name>` removes a global install (manifest + `~/.metascript/bin/` shim). |
| `msc install` | Verify locked deps are present, install commands into `.msc/bin/`; refuses git entries, transitive registry deps, a missing `msc.lock` and a registry/git dep it has no entry for. `-g <spec>` = global (see shims). |
| `msc x <cmd> [args…]` | Run a declared command. No argument lists them. |
| `msc publish [--dry-run]` | Pack `package.files`/`package.ignore` selection and upload with the stored token; the metadata sent to the registry carries `bin`, so the registry can show which commands a package installs (server-side exposure pending — `.inbox/landing/pkg-bin-metadata.md`). `--dry-run` prints the resolved list — measured: `files: 3 … build.ms, src/index.ms, tooling/cli.ms`. |
| `msc login` / `msc logout` | GitHub device-flow OAuth → registry bearer token in `~/.metascript/credentials` (mode 0600); logout revokes server-side then truncates. |
| `msc whoami [--json]` | Verify the token against the registry. Measured with a rejected token: exit 1, `error: token rejected by registry (expired or revoked)`. |
| `msc org …` | Registry organization management (`src/compiler/package/org.ms`). |

There is no `msc update` yet — bump versions by editing `build.ms` / re-running `msc add`.

Publish metadata (`description`, `license`, `repository`, `homepage`, `keywords`, `author`, and
`bin`) and file selection (`files`, `ignore` — `.gitignore`-subset globs; `.git/`, `out/`,
`.msc/`, `msc.lock`, `.env*` and friends are always excluded) live on the `package` block.
`~/.metascript/cache/` holds registry archives (`download/registry/<name>/<version>.zip`) and their
extracted files (`extracted/`); `src/compiler/package/cache.ms` owns the layout and also names git
paths, which nothing writes yet. No command binary lives there.

## Verified / not verified

Measured 2026-09-22 on `msc` v0.2.55 (installed build `b201f063`; hardening behaviours on
worktree candidates): `entry`/`outFile`/`optimize` builds, dep import by name+subpath, `file:`
add/remove, `msc x` (before and after upgrade), project + global shims, both refusal gates, the
foreign-shim refusal, `remove -g`, `publish --dry-run`, `whoami` error path, `msc init` scaffold.
The macro sandbox was probed with the same dependency source under a redirected
`~/.metascript/cache/`: before the change it wrote `/tmp/msc-sandbox-red/pwned`; after the change
`msc check` exits 1 naming `msFsWriteFileMode` and the dependency module, and the file is absent.
A cached macro using `msFsExists` plus a project-local macro using `msProcessPlatform` both check
clean.

Measured 2026-10-24 with a candidate built from `516108dbf`, `HOME` redirected to an empty
directory and the archive served from `http://127.0.0.1`: a lock entry with `url` and the archive's
`integrity` and an empty cache printed `downloading probepkg@1.0.0...`, `extracted probepkg@1.0.0
(2 files)`, `all 1 dependencies OK`, leaving `cache/download/registry/probepkg/1.0.0.zip` and
`cache/extracted/probepkg@1.0.0/{build.ms,index.ms}` and nothing else but `.update-check`. A build
importing it printed `hello from cache`. After editing the cached `index.ms`, the next build printed
`TAMPERED` and `msc install` still printed `all 1 dependencies OK`. With an empty cache and a
changed or absent `integrity`, `msc install` printed `error: probepkg@1.0.0: integrity missing or
mismatched` and `1 missing, 0 OK`, exit 1. A hand-written git entry with `commit: "abc123"` and a
directory at `cache/extracted/github.com/acme/foo@abc123/` built and printed `from git cache`;
removing the `commit` gave `Cannot resolve module 'foo/index'`; `msc install` refused the entry.
Not verified: a `file:` dep's transitive deps through the cache, Windows paths, a real registry.
