# Compiler CLI — Remaining Gaps

Comparison baseline: Nim, Zig, Rust. Current parity: ~75% Nim, ~55% Zig, ~40% Rust.

## Done

- [x] Function visibility: non-exported functions get `static` prefix
- [x] Separate compilation: per-module `.c` → `.o` → link (replaces unity build)
- [x] Cross-module prototypes: shared exported proto header injected into each `.c`
- [x] `-iquote` for runtime includes (prevents system header shadowing)
- [x] Compiler detection (clang/gcc/cc), build modes (debug/release/danger)
- [x] `cmdTest()` multi-module test execution with separate compilation
- [x] Change detection: mtime-based skip (`needsRebuild`), `--force`/`-f` override
- [x] Dependency file output: `--gendeps` writes `.deps` with module paths
- [x] Cross-platform naming: `exeSuffix()` adds `.exe` on Windows
- [x] Formatter: MVP delegate to reference compiler (`msc fmt`)
- [x] LSP server: 11 methods (hover, completion, definition, symbols, signature, inlay, references, rename)
- [x] Pipeline visibility: `dump-tokens`, `dump-ast`, `pipeline` commands
- [x] Raiser VM backend: `--target=raiser` + `cmdRunRaiser` bytecode execution
- [x] `msc clean` command: removes `out/` + `/tmp/_msc_*` temp files
- [x] `msc init [name]` command: scaffolds `build.ms` + `src/index.ms`
- [x] Init guards: `static NIM_BOOL guard_` on DatInit000/Init000 (double-init safe)
- [x] 3-category dispatcher: dependency Init000 before entry Init000 (correct ordering)
- [x] `--strip` flag: strips symbols from binary via `-s` linker flag
- [x] `--sanitize=<mode>` flag: ASan/UBSan/TSan passthrough to cc
- [x] `--passC`/`--passL` CLI flags: ad-hoc compiler/linker flag injection
- [x] `--emit=c` flag: write generated C to `out/` without compile/link

---

## Gap 1: Incremental Compilation

**Problem**: Every `msc build` recompiles all modules even if nothing changed.

### How Nim Does It (Two Levels)

**Level 1 — Generated .c content check** (`cgen.nim:2489-2511`):
- `shouldRecompile()` compares newly-generated C source byte-by-byte against existing `.c` file on disk via `equalsFile()`
- If `.c` content identical AND `.o` file exists AND `.o` is newer than `.c` → skip, set `CfileFlag.Cached`

**Level 2 — SHA1 footprint for external .c files** (`extccomp.nim:666-701`):
- `footprint()` computes `SHA1(fileContent + targetOS + targetCPU + compilerName + fullCompileCmd)`
- Stored in `.sha1` file next to the `.o` in nimcache
- `externalFileChanged()` compares stored hash vs current hash
- Skip decision (`extccomp.nim:984-987`): `if CfileFlag.Cached in it.flags: continue`

### Our Implementation Plan

**Approach**: Content comparison (Level 1 — simpler, no hash library needed).

**Files to modify**: `src/compiler/compile.ms` (`cmdBuildC`, `cmdTest`)

**Cache directory**: `.msc_cache/` in project root (gitignored).

**Algorithm per module**:
```
cCode = generateCModule(...)
cFile = ".msc_cache/" + mangleModuleName(modPath) + ".c"
oFile = ".msc_cache/" + mangleModuleName(modPath) + ".o"

if fileExists(cFile) && readFile(cFile) === cCode && fileExists(oFile):
    // Skip — .c unchanged and .o exists
    verboseLog("  cached " + modPath)
else:
    writeOutput(cFile, cCode)
    compileCFile(cFile, oFile, allFlags, mode, cc)
```

**What to add to `std/fs`** (or inline via `exec`):
- `readFile(path): string` — read file content for comparison
- Already have: `fileExists`, `writeOutput`, `exec("mkdir -p ...")`

**Cache invalidation**:
- `msc build --force` or `msc build -f` flag → skip cache check, recompile everything
- Changing compiler flags invalidates all (store flags in `.msc_cache/_flags.txt`, compare on build start)
- `msc clean` → `rm -rf .msc_cache/`

**Effort**: Medium. ~40 lines changed in compile.ms + readFile helper.

---

## ~~Gap 2: Init Guards~~ DONE

**Problem**: No protection against double-initialization if diamond dependency patterns exist.

### How Nim Does It

**Normal builds**: NO guard. Nim relies on each `Init000`/`DatInit000` being called exactly once from the dispatcher. The topological ordering guarantees this.

**HCR (Hot Code Reload) only** (`cgen.nim:2139-2158`): Uses `hcrRegisterGlobal("module_initialized_", ...)` which returns true on first call, false on subsequent.

### Our Implementation Plan

**Approach**: Simple `static bool` guard (cheaper than Nim's HCR approach, sufficient for our use case).

**File to modify**: `src/codegen/c/index.ms` → `genModuleInitFns()`

**Generated C code change**:
```c
// Before:
void myModule__Init000(void) {
  // user top-level code
}

// After:
void myModule__Init000(void) {
  static NIM_BOOL myModule__Init000_guard_ = 0;
  if (myModule__Init000_guard_) return;
  myModule__Init000_guard_ = 1;
  // user top-level code
}
```

Same for `DatInit000`.

**Code change in `genModuleInitFns`** (index.ms ~line 98):
```ms
// Add guard at start of Init000 body
addLine(procs, "void " + initName + "(void) {");
addLine(procs, "  static NIM_BOOL " + initName + "_guard_ = 0;");
addLine(procs, "  if (" + initName + "_guard_) return;");
addLine(procs, "  " + initName + "_guard_ = 1;");
```

**Effort**: Small. ~8 lines added to `genModuleInitFns`.

---

## ~~Gap 3: 3-Category Dispatcher~~ DONE

**Problem**: All modules in one flat topological list. System init not separated.

### How Nim Does It (`cgen.nim:1943-2065`)

Four builder buffers on `BModuleList`:
- `mainDatInit` — ALL modules' `DatInit000` calls + system module's `Init000` + TLS/GC init
- `otherModsInit` — regular modules' `Init000` calls
- `mainModInit` — main module's `Init000` only

**Call chain**:
```
main() → NimMain() → PreMain() → PreMainInner() → NimMainInner()

PreMain():
  ALL DatInit000 calls              (mainDatInit)
  systemInit000()                   (system module init, right after its DatInit)
  initThreadVarsEmulation()         (if needed)
  PreMainInner()
    moduleA__Init000()              (otherModsInit — regular modules)
    moduleB__Init000()

NimMainInner():
  NimMainModule()                   (mainModInit — main module's init only)
```

**Why separate main module**: Main module's top-level code runs LAST, after all dependencies initialized. This is important when main's top-level code calls functions from other modules that depend on those modules' global state being initialized.

### Our Implementation Plan

**File to modify**: `src/codegen/c/index.ms` → `genProjectDispatcher()`

**Change**: Split `MsMainInner` into two parts:

```ms
export function genProjectDispatcher(modulePaths: string[], entryPath: string, hasUserMain: boolean): string {
    // ... forward declarations unchanged ...

    // MsPreMainInner — ALL DatInit000 + non-entry Init000
    out = out + "static void MsPreMainInner(void) {\n";
    for (let i = 0; i < modulePaths.length; i += 1) {
        out = out + "  " + mangleModuleName(modulePaths[i]) + "__DatInit000();\n";
    }
    for (let i = 0; i < modulePaths.length; i += 1) {
        if (modulePaths[i] !== entryPath) {
            out = out + "  " + mangleModuleName(modulePaths[i]) + "__Init000();\n";
        }
    }
    out = out + "}\n\n";

    // MsMainInner — entry module Init000 + user main
    out = out + "static void MsMainInner(void) {\n";
    out = out + "  " + mangleModuleName(entryPath) + "__Init000();\n";
    if (hasUserMain) {
        out = out + "  main_();\n";
    }
    out = out + "}\n\n";
    // ... MsMain + POSIX main unchanged ...
}
```

**Effort**: Small. ~10 lines changed in `genProjectDispatcher`.

---

## Gap 4: Per-Module Proto Scoping

**Problem**: ALL exported prototypes injected into every `.c` file. Wasteful and produces duplicate declarations.

### How Nim Does It (`cgen.nim:1428-1550`)

**Demand-driven**: `genProcPrototype(m, prc)` is called only when module `m`'s codegen encounters a reference to `prc`. Tracked by `declaredProtos: IntSet` per module — each proto emitted at most once per `.c` file.

**Call flow** (`genProcNoForward`, line 1526):
```
Module A calls func from Module B:
  → genProcNoForward(A, prc)
  → findPendingModule(A, prc) → finds Module B
  → genProcPrototype(A, prc)     // emit proto in A's cfsProcHeaders
  → genProcAux(B, prc)           // emit body in B's cfsProcs
```

### Our Implementation Plan

**Approach**: During codegen pass 2, track which cross-module names each module actually uses via its import declarations. Only inject protos for those names.

**Files to modify**:
- `src/codegen/c/index.ms` — new `collectUsedImportProtos()` function
- `src/compiler/compile.ms` — build per-module proto map instead of single `allProtos` string

**Data flow**:
```
Pass 1: For each module, collect exported protos as before BUT index them by function name:
  protoMap: { "add": "double add(double a, double b);", ... }

Pass 2: For each module, look at its ImportDecl nodes to find which names it imports.
  Only inject protos for names that appear in its imports.
```

**New function in index.ms**:
```ms
export function collectExportedProtoMap(program: Node): string[] {
    // Returns alternating [name, proto, name, proto, ...] pairs
    // (can't use Map — not available, use parallel arrays)
}
```

**In compile.ms pass 2**:
```ms
// For each module, find its imports and filter protos
const imports = collectImportNames(pr.value);  // ["add", "square", ...]
let moduleProtos = "";
for (let j = 0; j < imports.length; j += 1) {
    const proto = lookupProto(allProtoNames, allProtoDecls, imports[j]);
    if (proto.length > 0) moduleProtos = moduleProtos + proto + "\n";
}
const cCode = generateCModule(analyzed, ctx, modPath, moduleProtos);
```

**Effort**: Medium. ~60 lines across index.ms and compile.ms. Need `collectImportNames()` helper to extract imported names from AST.

---

## Gap 5: Parallel Compilation

**Problem**: Modules compiled serially. N modules = Nx compile time.

### How Nim Does It (`extccomp.nim:971-1059`)

`callCCompiler()` → `execCmdsInParallel()`:
- Spawns up to `conf.numberOfProcessors` subprocesses
- Each subprocess runs one `clang -c module.c -o module.o`
- Polls for completion, spawns next when a slot frees
- Linking remains serial (must wait for all .o files)

### Our Implementation Plan

**Blocked**: MetaScript's `exec()` is synchronous (waits for completion). Need one of:
1. `execAsync(cmd): ProcessHandle` + `waitAny(handles): number` — new std/process API
2. Shell-level parallelism: `clang -c a.c -o a.o & clang -c b.c -o b.o & wait` — hacky but works
3. `make`-based: generate Makefile, run `make -jN` — delegates parallelism

**Option 2 (shell-level)** is implementable now without language changes:
```ms
// Build all compile commands, join with " & ", append " & wait"
let cmds = "";
for (let i = 0; i < compiled; i += 1) {
    if (i > 0) cmds = cmds + " & ";
    cmds = cmds + buildCompileCmd(cFiles[i], oFiles[i], flags);
}
cmds = cmds + " & wait";
exec(cmds);
```

**Caveat**: Error reporting is lost (can't tell which module failed). Post-check: verify all `.o` files exist.

**Effort**: Small for shell-level hack, Large for proper async subprocess API.

---

## ~~Gap 6: `clean` Command~~ DONE

**Problem**: No way to clear build artifacts. Users must `rm -rf out/` manually.

**How others do it**: `cargo clean` removes `target/`. Nim: manual `rm nimcache/`. Zig: manual `rm .zig-cache/`.

**Plan**: Add `msc clean` command. Removes `out/` and `.msc_cache/` (once incremental cache exists). ~10 lines in commands.ms + dispatch in index.ms.

**Files**: `commands.ms`, `index.ms`, `usage.ms`

**Effort**: Trivial.

---

## ~~Gap 7: `init` / Project Scaffold~~ DONE

**Problem**: No way to create a new project. Users must create files manually.

**How others do it**: `cargo new myapp` scaffolds `Cargo.toml` + `src/main.rs`. `zig init` creates `build.zig` + `src/main.zig`. `nimble init` creates `.nimble` + directory layout.

**Plan**: `msc init [name]` creates:
```
name/
  build.ms          # root = "src/index.ms", target = "c"
  src/
    index.ms        # function main(): number { console.log("hello"); return 0; }
```

If `name` omitted, scaffold in current directory. ~30 lines in a new `cmdInit()` in commands.ms.

**Files**: `commands.ms`, `index.ms`, `usage.ms`

**Effort**: Small.

---

## ~~Gap 8: `--strip` / `--debuginfo` Flags~~ DONE

**Problem**: No control over debug info or symbol stripping in output binary.

**How others do it**: Nim: `--strip:on`, `--debuginfo:on/off`. Zig: `--strip`. Rust: `-C strip=symbols|debuginfo`, `-C debuginfo=0|1|2`.

**Plan**: Add `--strip` flag → passes `-s` to linker. Debug info already emitted in debug mode (`-g`), but no way to force it in release or suppress it in debug. Add `--debuginfo=on|off` for explicit control.

**Files**: `options.ms` (parse flags), `cc.ms` (pass to compiler/linker), `usage.ms`

**Effort**: Trivial. 3 lines in cc.ms, 5 lines in options.ms.

---

## ~~Gap 9: Emit Intermediate Representations~~ DONE

**Problem**: No `--emit asm|c|ir` flag. Users can't inspect generated C without finding temp files.

**How others do it**: Rust: `--emit asm|llvm-ir|llvm-bc|mir|obj`. Zig: `--emit asm|llvm-ir|bin`. Nim: C source is always viewable in nimcache.

**Plan**: `msc compile --emit=c hello.ms` writes `.c` to output dir (already works — that's what `--target=c` does for single files). For multi-module `msc build --emit=c`, write all `.c` files to `out/debug/` instead of `/tmp/` and skip the compile+link step. Useful for debugging codegen.

**Files**: `options.ms` (add `emit: number`, 0=binary, 1=c-only), `compile.ms` (skip cc step when emit=c), `usage.ms`

**Effort**: Small. ~15 lines.

---

## Gap 10: Library Output (Static/Shared)

**Problem**: Can only output executables. No `--lib`, `--staticlib`, `--dylib` flag.

**How others do it**: Rust: `--crate-type lib|staticlib|cdylib`. Zig: `build-lib -dynamic`. Nim: `--app:lib|staticlib`.

**Plan**: Add `--lib` flag. Compiles all modules to `.o`, runs `ar rcs libname.a *.o` (static) instead of linking an executable. Skip dispatcher generation (no main). Dynamic libs (`-shared`) as follow-up.

**Files**: `options.ms` (add `outputType: number`, 0=exe, 1=staticlib), `compile.ms` (skip dispatcher, use `ar` instead of link), `usage.ms`

**Effort**: Medium. ~30 lines. Requires `ar` invocation helper in cc.ms.

---

## ~~Gap 11: Sanitizer Passthrough~~ DONE

**Problem**: No built-in way to enable ASan/UBSan/TSan.

**How others do it**: Nim: `--passC:"-fsanitize=address" --passL:"-fsanitize=address"`. Zig: built-in safety checks + `-fsanitize=`. Rust: `-Z sanitizer=address` (nightly).

**Plan**: `--sanitize=address|undefined|thread` flag. Appends `-fsanitize=X` to both compile and link flags. Since we target C, this is pure passthrough to clang/gcc.

**Files**: `options.ms`, `cc.ms` (append to flags), `usage.ms`

**Effort**: Trivial. ~10 lines total.

---

## Gap 12: Doc Generation

**Problem**: No `msc doc` command. No way to generate API documentation from source.

**How others do it**: Nim: `nim doc` generates HTML from `##` doc comments. Rust: `cargo doc` / `rustdoc` is best-in-class. Zig: experimental autodoc.

**Plan**: MVP — extract `//` comments above exported functions/types, emit Markdown. Parse the AST looking for ExportDecl nodes, collect preceding comment tokens (already in token stream as `Comment` kind), format as `## functionName\n\nsignature\n\ndoc text`.

**Files**: New `src/compiler/doc.ms` (~100 lines), `commands.ms` (add `cmdDoc`), `index.ms`, `usage.ms`

**Effort**: Medium. MVP ~100 lines. Full HTML generation significantly more.

---

## Gap 13: Cross-Module LSP

**Problem**: LSP is single-file scope. Can't jump to definitions in imported modules, no cross-module completions.

**How others do it**: `rust-analyzer` indexes the full workspace. ZLS does cross-file analysis. `nimsuggest` has partial cross-module support.

**Plan**: On `didOpen`, load the module graph from the file's entry point (or `build.ms` root). Cache the graph. For `definition`, resolve imported symbols through the graph's export registry. For `completion`, include exported symbols from imported modules.

**Files**: `src/compiler/lsp/server.ms` (graph caching, cross-module resolution), `src/compiler/lsp/` analysis functions

**Effort**: Large. Core graph caching ~50 lines, but wiring cross-module symbols into each LSP method is significant.

---

## Gap 14: Incremental Type Checking

**Problem**: Every edit triggers full reparse + 3-pass check of all modules. Slow for large projects.

**How others do it**: Rust: mature incremental via query-based architecture (salsa). Zig: hash-based caching. Nim: per-module C caching (doesn't cache type checking itself).

**Plan**: Cache `CheckerContext` results per module. On edit, only re-check the changed module and its reverse dependents. Requires: module graph diffing, serializable checker state, invalidation of downstream modules.

**Files**: `src/checker/`, `src/module/`, `src/compiler/lsp/server.ms`

**Effort**: Very Large. Architectural change to checker. Defer until LSP cross-module (Gap 13) is done.

---

## Gap 15: Warning System

**Problem**: No compiler warnings. Errors are fatal, but there's no "this is suspicious but valid" category.

**How others do it**: Nim: hints + warnings + `--styleCheck`. Zig: warnings-to-errors flag. Rust: `allow/warn/deny/forbid` per lint, clippy has 600+ rules.

**Plan**: MVP — add `warnings: string[]` to CheckerContext alongside `errors`. Populate with: unused variables, unused imports, shadowed names, unreachable code after return. Display with yellow "warning:" prefix. Add `--warn=error` flag to promote to errors.

**Files**: `src/checker/context.ms` (add warnings array), `src/checker/checkPass.ms` (emit warnings), `src/compiler/io.ms` (print warnings), `options.ms`, `usage.ms`

**Effort**: Medium for infrastructure, Large for comprehensive lint rules.

---

## Gap 16: Self-Hosted Formatter

**Problem**: `msc fmt` delegates to reference compiler. Not truly self-hosted.

**How others do it**: Zig: `zig fmt` is canonical, non-configurable. Rust: `rustfmt` is configurable via `rustfmt.toml`. Nim: `nimpretty` is basic.

**Plan**: Parse source → walk AST → emit formatted output. Key decisions: tab vs spaces (we use tabs), max line width, brace style. Zig's approach (canonical, non-configurable) is simplest. Reuse existing lexer + parser, write a printer that emits formatted code.

**Files**: New `src/compiler/fmt.ms` (~300 lines), update `commands.ms`

**Effort**: Large. AST-aware formatting is non-trivial. ~300-500 lines.

---

## ~~Gap 17: `--passC` / `--passL` CLI Flags~~ DONE

**Problem**: `@passC`/`@passL` directives work in source code, but there's no CLI equivalent for ad-hoc flags.

**How others do it**: Nim: `--passC:"..."`, `--passL:"..."`. Rust: `cargo rustc -- -C ...`. Zig: build.zig API.

**Plan**: `--passC="..."` and `--passL="..."` CLI flags. Append to `allFlags` string in compile.ms alongside directive-collected flags.

**Files**: `options.ms` (parse), `compile.ms` (merge into allFlags), `usage.ms`

**Effort**: Trivial. ~10 lines.

---

## Priority Order

### Tier 1 — Trivial (< 15 lines each, do first)
1. ~~**Gap 6: `clean` command** — table stakes, 10 lines~~
2. ~~**Gap 8: `--strip`/`--debuginfo`** — passthrough to cc, 8 lines~~
3. ~~**Gap 11: `--sanitize`** — passthrough to cc, 10 lines~~
4. ~~**Gap 17: `--passC`/`--passL` CLI** — passthrough, 10 lines~~

### Tier 2 — Small (15-50 lines, high ROI)
5. ~~**Gap 2: Init guards** — 8 lines, safety correctness~~
6. ~~**Gap 3: 3-category dispatcher** — 10 lines, init ordering correctness~~
7. ~~**Gap 7: `init` command** — 30 lines, first-run experience~~
8. ~~**Gap 9: `--emit=c`** — 15 lines, codegen debugging~~

### Tier 3 — Medium (50-100 lines)
9. **Gap 1: Incremental compilation** — 40 lines, biggest iteration speed win
10. **Gap 4: Per-module proto scoping** — 60 lines, cleaner C output
11. **Gap 10: Library output** — 30 lines, unlocks library use case
12. **Gap 15: Warning system** — 50 lines for infra, ongoing for rules

### Tier 4 — Large (100+ lines)
13. **Gap 5: Parallel compilation** — blocked on async exec or shell hack
14. **Gap 12: Doc generation** — 100 lines MVP
15. **Gap 16: Self-hosted formatter** — 300+ lines
16. **Gap 13: Cross-module LSP** — 200+ lines, high impact
17. **Gap 14: Incremental type checking** — architectural, defer
