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
(`{ from, names }`, …) are accepted but only `from` is read — an entry always injects the module's
full export surface.

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

- `resolve.alias` — extracted, passed to the resolver, and still `Cannot resolve module` for both
  `"@lib": "./src/lib"` and `"lib": "./src/lib"`.
- `root` — declared in `std/build`'s `BuildConfig` and written by `msc init`, but the loader reads
  `entry` only. A fresh `msc init` scaffold does not build (`error: build requires an input file`)
  until you rename `root:` to `entry:`.
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
| `"git:github.com/owner/repo@v1.2.3"` | git host archive, tag or 40-char SHA | `msc.lock` |

There are no range operators — `^`, `~`, `>=`, `*` are errors, by design: every version is an
exact minimum and resolution is Maximum Version Selection (one version per package, the highest
minimum wins, no backtracking). `devDeps` are for tests and tooling; both are compiled and both
may declare commands.

### Importing a dependency

Every dependency becomes an import alias bound to its folder (`depRoots`, `src/compiler/compile.ms`),
so source imports it by name plus subpath:

```ms
import { greeting } from "greeter/src/index";
```

`file:` deps are followed transitively (a dep's own `build.ms` `deps`/`devDeps` are read, depth
capped at 20). Registry/git deps resolve through `msc.lock` to `~/.metascript/cache/src/…`.

### `msc.lock`

Plain JSON, written by `msc add` for registry and git sources, read by every build. `file:` deps
never appear in it — moving the folder is the upgrade. Reader/writer: `src/compiler/package/lockfile.ms`.

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
(`file:` deps, `msc.lock`, then the global manifest), builds the entry and executes it.
**Everything after the command name belongs to the command**, including flags — `msc x greet
--release` passes `--release` to `greet`. The command's exit status is the exit status of `msc x`.

- `msc x` with no argument lists the declared commands.
- Two packages declaring one name is not an error until you run it: `msc x greeter:greet` picks one.
- A registry/git command is built once into `~/.metascript/cache/bin/<pkg>@<version>/<command>`
  and executed from there afterwards; a `file:` command is rebuilt on every run, because its
  source can change under you. The build lands through a temp file and an atomic rename — two
  concurrent first runs cannot hand each other a half-written binary — and the cache holds at
  most 32 package directories (`BIN_CACHE_CAP`, `src/compiler/x.ms`), evicting the
  least-recently-used; an evicted command simply rebuilds on its next run.

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

**Building runs package code.** MetaScript macros and decorators execute during compilation —
in the Raiser VM, with host `fs`/`process` functions available (`src/compiler/meta/`,
`src/raiser/hostRegistry.ms`). So the first `msc x` of a dependency executes that dependency's
macro code on your machine before its command ever runs — the same trust position as Cargo's
`build.rs`. `msc.lock` pins the *identity* of registry/git sources (SHA-256 integrity, commit),
which makes builds reproducible, not audited: pinned ≠ trusted. Until dependency macro
execution is sandboxed (an open design question), treat `msc x` on an untrusted package exactly
as you would treat running it.

## Command reference

| Command | Behavior |
|---|---|
| `msc init <name>` | Scaffold `build.ms` + `src/index.ms`. **Currently writes `root:` where the loader wants `entry:`** — rename it before `msc build` (see "not wired"). |
| `msc add <spec> [-D]` | Add a dep to `deps` (or `devDeps` with `-D`) in `build.ms`, then install commands. Spec: `name` (registry latest), `name@1.2.3`, `name@git:host/path@ref`, `name@file:path`. Also rewrites `msc.lock` for registry/git. |
| `msc remove <name>` | Remove the dep from `build.ms` + `msc.lock`, then prune its shims from `.msc/bin/`. `-g <name>` removes a global install (manifest + `~/.metascript/bin/` shim). |
| `msc install` | Verify locked deps are present, install commands into `.msc/bin/`. `-g <spec>` = global (see shims). |
| `msc x <cmd> [args…]` | Run a declared command. No argument lists them. |
| `msc publish [--dry-run]` | Pack `package.files`/`package.ignore` selection and upload with the stored token; the metadata sent to the registry carries `bin`, so the registry can show which commands a package installs (server-side exposure pending — `.inbox/landing/pkg-bin-metadata.md`). `--dry-run` prints the resolved list — measured: `files: 3 … build.ms, src/index.ms, tooling/cli.ms`. |
| `msc login` / `msc logout` | GitHub device-flow OAuth → registry bearer token in `~/.metascript/credentials` (mode 0600); logout revokes server-side then truncates. |
| `msc whoami [--json]` | Verify the token against the registry. Measured with a rejected token: exit 1, `error: token rejected by registry (expired or revoked)`. |
| `msc org …` | Registry organization management (`src/compiler/package/org.ms`). |

There is no `msc update` yet — bump versions by editing `build.ms` / re-running `msc add`.

Publish metadata (`description`, `license`, `repository`, `homepage`, `keywords`, `author`, and
`bin`) and file selection (`files`, `ignore` — `.gitignore`-subset globs; `.git/`, `out/`,
`.msc/`, `msc.lock`, `.env*` and friends are always excluded) live on the `package` block.
`~/.metascript/cache/` holds registry and git downloads plus command binaries;
`src/compiler/package/cache.ms` owns the layout.

## Verified / not verified

Measured 2026-09-22 on `msc` v0.2.55 (installed build `b201f063`; the hardening behaviours —
marker shims, foreign-file refusal, prune on remove, `remove -g`, install listing — on a
worktree build carrying `55a8c5ce`): `entry`/`outFile`/`optimize` builds, dep import by
name+subpath, `file:` add/remove, `msc x` (before and after upgrade), project + global shims,
both refusal gates, the foreign-shim refusal, `remove -g`, `publish --dry-run`, `whoami` error
path, `msc init` scaffold.
