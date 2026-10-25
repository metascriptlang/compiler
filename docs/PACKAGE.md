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
`file:` deps) is relative to it (`findProjectRoot`, `src/index.ms`).

**Accepted forms** (`findConfigObject`): `const config: BuildConfig = { … }; export default config;`
(the idiomatic form), `export default { … };`, and `defineConfig({ … })`.

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

### `cc` — C compiler and flags

`cc.compiler`, `cc.flags`, `cc.linkFlags` apply to every build; `cc.targets` keys on `"<os>-<cpu>"`
(`linux-amd64`, `windows-arm64`, …) override them when cross-compiling that target, and each
target may carry its own `entry`. Resolution order: per-target config > `cc.*` defaults >
well-known cross-compiler (`resolveCcForTarget`, `src/compiler/buildConfig.ms`). CLI `--cc=`,
`--passC=`, `--passL=` override all of it.

### `globalImports`

Module paths whose exports land in scope of every source file, injected before command dispatch
(`src/index.ms`). `std/`-prefixed specifiers pass through; absolute paths are normalized; anything
else is joined to the project root. Entries are extension-less. Precedence: a local declaration
wins over an explicit import, an explicit import wins over the injection. The object-entry forms
(`{ from, names }`, …) are accepted but only `from` and `modulePass` are read — an entry always
injects the module's full export surface.

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

Under `--hcr`, a globalImports module that keeps a module-level `string[]` fails to link, with
or without a pass (card `2026-10-06-hcr-ref-array-cell-owned-by-user-image.md`).

### `lsp` — editor-only target

`lsp: { os, gc }` tells the language server which target to judge against; `msc build` ignores it
entirely. `os` defaults to the host; `gc` is inferred from it (`bare`/`solana` ⇒ `manual`, else
`orc`). Its one measurable effect: when the effective gc is `manual` and the open file is not
under `std/`, every async site gets FREESTANDING E01 as a *warning* — measured (2026-09-06, real
stdio LSP): `lsp = { os: "bare" }` → 3 warnings on a 3-async-site file; no `lsp` section, or
`gc: "drc"` → 0. A project that declares nothing keeps exactly the diagnostics it had. Unknown
`os`/`gc` values are reported when the editor opens `build.ms` itself (`validateBuildConfig`,
LSP-only).

### Declared but not wired — do not rely on these yet

Measured 2026-09-22, card `~/metascript/.inbox/compiler/2026-09-22-build-ms-declared-but-unwired.md`:

- `resolve.alias` — wired for `msc build`, `msc check` and `msc run --target=raiser`, and the value is read relative to
  the importing file's directory, not the project root. Measured 2026-10-25 with `msc` v0.3.4
  (`~/.metascript/BUILD` binary `6b8655024`), entry `src/main.ms`: `"@lib": "../lib"` resolves
  to `<root>/lib` and `"./lib"` to `src/lib` under `msc build`; an alias used from
  `src/deep/m.ms` with `"../lib"` resolved to `src/lib`; an absolute path resolves;
  `"./src/lib"` stops with `Cannot resolve module` (also under the name `lib`). `msc run
  --target=raiser` resolves the same aliases (measured on a candidate built from this branch,
  2026-10-25: `deep:src-lib`); `msc run` on C and `--target=js` stops with `Cannot resolve module
  '@lib/util'`. Not verified: Windows paths, an alias target outside the project.
- `root` — declared in `std/build`'s `BuildConfig` as the base for non-relative imports, and read
  by nothing. Measured 2026-10-15 on a candidate built from `7e7c0dd02`: with `root: "src"` or
  `root: "."`, `import … from "lib/util"` and `from "src/lib/util"` both stop with `Cannot resolve
  module`, exactly as without the field; only `./lib/util` resolves.
- Importing a dep by its bare root (`import { greeting } from "greeter"`) fails; the subpath form
  `from "greeter/src/index"` works (see below).

`resolve.searchPaths` / `resolve.extensions` are not extracted at all.

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
(`reservedCommands`, `src/compiler/package/bin.ms`); the entry must be a relative `.ms` path
inside the package and must exist.

**The dep stays when the command is refused.** `msc add rival` above writes `rival` into
`build.ms` first, then refuses to install the colliding command — the dependency is the thing
you asked for, the command is a derived effect, and the refusal names both claimants so you can
drop one or address it as `msc x <package>:greet`. Rolling the dep back would undo the requested
operation to save you from a side effect you were just told about.

### Running one — `msc x`

`msc x <command> [args…]` resolves the command against every dependency the project can see
(`file:` deps, `msc.lock`, then the global manifest) and runs the entry on Raiser from source.
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
| `msc init <name>` | Scaffold `build.ms` with `entry: "src/index.ms"` + `src/index.ms` ending in a bare `main();`, so `msc build` / `msc run` take the project without a file argument. Measured 2026-10-15: inside a fresh scaffold, `msc build` printed `Built 1 module(s) → out/debug/index` on a candidate built from `7e7c0dd02`, where v0.3.4 (`15b93cbba`) stopped with `error: build requires an input file` because it wrote `root:`. |
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
