# BUILD-PERF — Build Speed: Findings, Architecture, Roadmap

> Tracking doc for the build-performance workstream. Agreed 2026-09-01.
> Update §8 as phases land. All measurements below were taken on the Windows
> host, warm caches, tree at `82f4e5d6`-era HEAD, unless noted otherwise.

---

## 1. Problem statement (measured)

| Workload | Cost today | Where it goes |
|---|---|---|
| corpus parity lane | ~15–19 min | ~140 programs × 4 lanes ≈ 560 cells, serial subprocess builds |
| warm single build (`msc build prog.ms`) | ~1.5 s wall / 1357 ms internal | see §1.1 |
| self-host full build (`--danger`) | 17.65 s | front end dominates (same class as the ~21 s suite floor) |

### 1.1 Warm build decomposition (`--time`, corpus program `011-truthy` — 15 LOC, ZERO imports)

| phase | ms | share | note |
|---|---|---|---|
| graph load+check | 702 | 52% | **the bottleneck — re-done from scratch every process** |
| phase D link | 306 | 23% | per-cell binary, not cacheable |
| phase A parse+check+transform | 288 | 21% | the program's own modules (xform=204ms) |
| phase B DCE | 8 | 1% | |
| phase C codegen + clang | 52 | 4% | **object cache works — codegen is NOT the problem** |
| process spawn (outside timers) | ~150 | — | ×560 on corpus |

Toolchain-stamp cost (hashes msc binary + runtime/ + vendor/ every invocation,
added 2026-09-01): ~30–70 ms — negligible; correctness worth it.

### 1.2 Full decomposition of the 708–828 ms graph load+check (Phase 0, 2026-09-01)

Instrumented run (`--time`, same program; loader-half timer added in
`loadAndCheckGraph`, orchestrator PROFILE under `-t`):

| block | ms | what it is |
|---|---|---|
| `graphLoad: preludeMods` | **236** | loader parses all 45 std modules into the graph — **stdlib parse #1** — of which **`inlineHeader`=175 ms (74%)** is C-header translation (`inlineHeaderImports`, runs over every module) |
| `prelude` | **303** | `buildPreludeContext` → `loadPreludeOne` ×15: read + **inlineHeaderImports AGAIN** + parse + threePasses + ensureShaped — **parse #2, check #1** |
| Phase 1 (`p1parse+p1collect`) | **61** | orchestrator parses ALL graph modules again — **parse #3** |
| Phase 2 (`p2parse`…`p2exports`) | **190** | parses all modules a 4th time + inject + the real per-module check + exports — **parse #4, check #2** |
| misc (report, finalize) | ~10 | |

**The finding: the stdlib is parsed 4× and checked 2× per process — for a
15-LOC program whose own entry tree costs 0.19 ms.** The single largest
line-item is `inlineHeaderImports` (175 ms in the loader + a large share of
the 303 ms prelude block — it runs again there): a PURE string transform
(source + `.h` contents → source with extern decls inlined) paid twice per
build, every build. Also notable: `checkCallExpr` n=3856 → 44 ms inside the
checker (hot-loop track); `node.ms` alone 114 ms in phase A (transform half
of `xform=204 ms`).

### 1.3 Root cause: fat implicit prelude × zero cross-process reuse

- `defaultGlobalImports()` (`src/checker/prelude.ms:11`) injects **15 std
  modules into every program**, including the heavy ones: `fetch`,
  `websocket`, `json`, `bigint`, `date`, `performance`…
- Transitive closure for a **zero-import 15-LOC program = 45 modules
  (~500 KB)**: json tree (10 modules), fetch (7 — pulls crypto 54 KB, net,
  tls), websocket (6 — 113 KB), meta (`node.ms` 50 KB).
- DCE discards them right after check (`skip (dead)`) — but everything in
  §1.2 was already paid.
- Batch `msc build` runs the classic pipeline; **only the LSP uses TransAm**.
  No cross-process caching exists.
- Corpus: 560 serial subprocesses × ~0.8 s front end ≈ **7 min/lane of pure
  redundancy**. Plus ~560 × 150 ms spawn ≈ 1.4 min.
- Model check: 560 × 1.5 s + cold passes + runs ≈ 15–19 min ✓ matches.

---

## 2. Directions considered

| Direction | Verdict | Why |
|---|---|---|
| Slim `defaultGlobalImports` (Nim `nimPreviewSlimSystem` model) | **rejected by product decision** | implicit stdlib surface is a language promise (user rejected). Keep as documented fallback if this whole plan fails |
| Lazy name-scan prelude selection | rejected | no reference precedent; false-negative risk (comptime-generated names, extensions) |
| Whole-context snapshot / Nim-IC style | rejected | Nim's IC attempts (rod → sqlite → NIF) never became default; persisting whole contexts is the graveyard |
| Daemon / persistent worker (Bazel worker protocol) | superseded | disk persistence + `--batch` give the same wins without IPC; a daemon would be built then obsoleted |
| Checker hot-loop profiling | **keep as parallel track (cheap)** | `node.ms` 2.4 ms/KB vs graph avg 1.4 ms/KB suggests quadratic spots; current `--time` does not even decompose the 702 ms |

Product constraints honored: implicit surface stays; subprocess-per-cell
stays available (two-tree convention: `MSC=` subject, bisect/A-B, isolation).

---

## 3. Chosen architecture: batch on TransAm + persisted std interfaces

TransAm (`src/compiler/transam/`, 11 files) is a complete in-RAM Salsa engine
(red-green, content-addressed `hashNode`, LRU + permanent High-durability
cache for stdlib, queries through `dbAnalyze`). LSP-only today. The plan is
to finish the two missing pieces rather than invent anything:

### Phase 0 — Instrument the 702 ms (prerequisite, hours)

Add fine-grained `printTiming` to `loadPreludeOne` / orchestrator prelude path
so the graph-load cost decomposes per module and per sub-phase. De-risks A
and feeds the hot-loop track.

### Phase A0 — disk cache for `inlineHeaderImports` (NEW 2026-09-01, do FIRST)

Measured: 175 ms in the loader half + a second pass inside
`buildPreludeContext` — the single biggest redundant line-item, and it is a
**pure function** `(module source, referenced .h contents) → inlined source`.
Cache its output on disk, content-hash keyed
(hash of module source + of every referenced header), namespaced by
toolchainStamp (headers under runtime/ + vendor/ are already stamped —
today's plumbing). String-in/string-out — zero semantic risk, no symbol
serialization, no IC trap. Expected: −250…−300 ms per build; corpus
−2…−3 min/lane; benefits every build including self-host.
Implementation: wrap `inlineHeaderImports` (loader.ms) — key → read cache →
hit: return; miss: compute + atomic publish. Kill-switch env
`MSC_NO_HEADER_CACHE=1`.

**Reference model (nothing invented):** the reference compiler has no
header-translation step at all — its FFI bindings are hand-written
declarations (`.importc.` pragmas; verified lib/system.nim), so it never
pays this cost. The mechanism itself is the established
"cache a pure transform's output, content-hash keyed" family:
Zig `@cImport` (translate-c output cached in the content-addressed local/
global cache, keyed by header hashes + options — the closest analog: C
header → translated source, cached), ccache (hash of preprocessed input +
compiler + flags → cached object), clang/GCC PCH (cached header
pre-processing), and the same principle we already ported from the
reference's extccomp json build-instructions for the `.o` object cache.
A0 applies that principle to the one transform we have that the reference
doesn't.

### Phase A — Disk interface cache for std modules (the immediate lever)

Persist, per std module, the **interface artifact downstream actually
consumes** — NOT a whole `CheckerContext`:

```
~/.metascript/cache/iface/<moduleContentHash>.if
  header   : magic + toolchainStamp + module path + counts
  symbols  : exported syms; flat Type interface (kind/typeName/typeChildren/
             typeReturn/typeExtra/typeFlags) serializes naturally
  exts     : extension registrations
  macros   : LAZY markers (source path + span) — do NOT serialize AST in v1
  names    : string table; re-intern into IdentCache on load (rustc model)
```

- **Format: custom flat binary, not JSON.** Load target ≤50 ms for all 46
  modules; JSON parse eats the win and drags number-fidelity risk
  (cf. corpus `512-jsonInt64`). Binary is industry norm for hot compiler
  caches (rustc rmeta, clang PCM, GCC PCH).
- **No format versioning needed**: namespace = `toolchainStamp` (contains msc
  binary hash) — any compiler rebuild invalidates automatically.
- Publish with existing `atomicWriteFile`/`renameReplace` (same
  concurrency-safe mechanism as the `.o` cache, e9ba1ef2).
- Lifecycle rides the existing `.version` marker wipe (GC) — zero new code.
- Cold path = today's behavior + writes blobs ("warm the cache").
- Fallback: stamp/parse miss → full check, regenerate.
- Generic instantiation / `@comptime` / const-fold need bodies → v1 re-parses
  the defining module source lazily on demand.
- Debug affordance: `--dump-iface` emits JSON for humans; binary stays the
  hot path.

### Phase B — Route batch build onto TransAm

`compile.ms` pipeline (through analyze) executes as TransAm queries in the
batch `msc build` path too. This is what attacks the **21 s self-host
floor** (persist/extend beyond stdlib: unchanged user modules also skip).
Queries must be parameterized by the options that stamp prelude contexts
(`targetOs` at least — see orchestrator notes; Salsa input-keys handle this).

### Phase C — `--batch` CLI (corpus sugar, thin wrapper over B)

`msc build --batch manifest` → one subject process builds a whole lane:
spawn 560→4, prelude checked once in RAM. Corpus default becomes batch with
per-cell fallback preserved for bisect/isolation. Accept the trade-off: a
compiler segfault kills the batch, not one cell.

### Economics

```
today      560 × (150 spawn + 702 prelude + …) ≈ 8 min overhead/lane
after A    560 × (150 spawn +  50 load   + …) ≈ 2 min overhead/lane
after C      4 × (150 spawn + 702 once)       ≈ seconds overhead/lane
```

Who benefits (A alone): user builds (any size), corpus, `msc test`, LSP
startup (§10 of transam/CLAUDE.md anticipated exactly this). B additionally:
self-host/suite floor.

---

## 4. Reference lineage (read before building)

| Concept | Reference |
|---|---|
| in-RAM query engine | Salsa / rust-analyzer (TransAm already ports it; transam/CLAUDE.md has file:line cross-refs) |
| batch compiler ON the engine | rustc — batch is query-driven by design; our batch-off-engine is the divergence |
| disk persistence of query results | rustc incremental compilation (rustc-dev-guide, "Queries" + "Incremental compilation" chapters) |
| interface artifact at library boundary | rustc `rmeta`/`rlib` (rustc-dev-guide "Libraries and metadata" — verified 2026-09-01); TypeScript `.d.ts` same family |
| invalidation | content hashes (`hashNode` exists) + SVH-analog = `toolchainStamp` (hardened + marker GC, 2026-09-01) |
| anti-reference | Nim IC — persisting whole contexts; also Zig's laziness = different axis, not retrofittable |

Local reference trees: `~/projects/nim` (yes). rust/rust-analyzer: NOT on
this Windows host — clone or read via web when needed.

---

## 5. Verification ladder (per phase)

1. `msc test src/index.ms` — baseline 3515/3513-era, 174 files, 0 fail.
2. corpus parity (Windows host: llvm-mingw PATH prepended): 698/0/5 target,
   SAN lane 158/0/1 (as of 2026-09-01 with the danger-lane flags fix).
3. self-host fixpoint: gen-N vs gen-N+1 emitted-C 0 differ.
4. Phase A specific: interface-cache cold/warm/flip matrix — flip a std
   header → stamp moves → blob regenerated (mirror of today's vendor-stamp
   proven-red methodology).

## 6. Phase A design (v1 — settled 2026-09-01, implementation pending)

### 6.1 Consumption contract — what the blob must reconstruct

Derived by reading the consumers (not invented): `injectPrelude`
(checkPass.ms:2483-2541) is THE downstream contract for the prelude context;
the loader (`loadPreludeModules`, compile.ms:368) and P2 exports
(`buildExportInfo`, context.ms:195-324) are the contracts for A2/A3.

The pack must rebuild, exactly:
1. `table.current.symbols` — exported Symbols (name, symbolKind, flags,
   type, overloads, declModule). NOTE `Scope.symbols` is `Map<int32, Symbol>`
   keyed by IdentCache nameId — ids are per-session, pack stores names.
2. macro registries (`macroBodyRegistry`/`macroParamsRegistry` = AST,
   `macroParamTypesRegistry`, `macroDeclModuleRegistry`) — see lazy rule
3. converter pairs (`converterTargetByName`/`converterTargetTypes`)
4. `extensionRegistry.methods` — ExtMethod{methodName, receiverTypeName,
   sourcePath, fnType, isStatic, sym, depth=0}
5. `includeDirectives` + `compilerFlags` (the @passC/-I strings — load-bearing
   for the build, cf. the 32767-char dedup fix)
6. targetOs — part of the KEY, not the payload
7. (A2) per-module dep-list + topo order; (A3) per-module ExportedSymInfo

**AST-carrying exports (rmeta pattern, already in `buildExportInfo`)**:
cross-module symbols carry selective AST — generic FunctionDecl/MethodDecl
bodies (mono), EnumDecl, non-generic fn bodies (Raiser @comptime walker),
`defaultParams` exprs. A prelude pack that skips source must either
serialize this subset or fall back to source for the roots that need it.
**Open empirical question (census before impl)**: which of the 15 roots
export AST-carrying syms, and how big that subset is. Type↔Symbol is
bidirectional (`Type.sym` ↔ `Symbol.symbolType`) — sections reference each
other by u32 index (planned), cycles are fine.

### 6.2 One pack, not per-module files (v1)

The prelude loads all-or-nothing (15 roots always together) → a single
`prelude pack` is simpler and loads in one read.
Key = hash(toolchainStamp ‖ targetOs ‖ backendExt ‖ Σ contentHash(46 std
sources)). Any std/vendor/compiler change → new key → regenerate. Per-module
granularity deferred until proven needed.

### 6.3 Layout — custom flat binary

```
~/.metascript/cache/prelude/<keyHash>.ifp      (atomic publish, marker-GC'd)
[header] magic "MSIF", fmt=1, stamp, keyHash, section counts
[strtab] deduped name/source strings (→ re-intern into IdentCache on load)
[types] flat Type records; typeChildren as u32 indices into this section
[syms]  {nameIdx, kind, flags, typeIdx, overloads[u32→syms/types], declModuleIdx}
[exts]  ExtMethod records (fnType → types idx)
[macros] {nameIdx, definingModulePathIdx, span}   ← LAZY, see 6.4
[conv]  converter pairs
[dirs]  includeDirectives, compilerFlags
[mods]  (A2) per std module {pathIdx, sourceHash, deps[pathIdx]}
[exports] (A3) per module ExportedSymInfo list
```

### 6.4 Lazy rules (v1)

- Macro bodies: if the pack lists ANY exported macro, re-parse the defining
  module source (parse-only, ~10 ms) to recover bodies. Census first — if
  std exports zero macros this path is dead code and stays unexercised.
- Mono instantiation / const-fold of std bodies: unaffected in A1/A2 (P1/P2
  still run); A3 must design lazy program materialization (with TransAm B).

### 6.5 Flow

- `buildPreludeContext`: try `loadPack(key)` → miss → today's path, then
  `writePack` at the end of a successful fresh build (serialize from the
  live ctx; `atomicWriteFile`).
- Names are stored as strings and re-interned at load (rustc model); numeric
  ids never persist.
- Type identity: downstream is structural (`isAssignable`), so fresh type
  objects are fine — audit for pointer-keyed caches during impl.

### 6.6 Staging (risk-ordered) and expected wins

| Stage | Replaces | Saves (measured) | Risk |
|---|---|---|---|
| A1 pack for `buildPreludeContext` | prelude=314 ms block | −314 ms/build | contained — prelude ctx is a pure producer |
| A2 loader seeds std graph from pack dep-lists | graphLoad=257 ms | −257 ms | loadOrder fidelity |
| A3 skip P1/P2 + phase-A transform for cache-hit std modules | P1+P2=247 ms + ~180 ms transform | −427 ms | deep — lazy programs, do WITH TransAm B |

A1+A2: warm build ~1.5 s → ~0.9 s; corpus −~4.5 min/lane. +A3 → ~0.6 s.

### 6.7 Verification (A1/A2)

- Byte-identical emitted C with pack ON vs OFF (kill-switch env
  `MSC_NO_PRELUDE_PACK=1`) across a program set — fixpoint-style.
- Flip a std header → stamp moves → pack regenerates (mirror of the
  vendor-stamp proven-red methodology).
- Full ladder (§5).

### 6.8 Still-open (settle during impl)

- Symbol/overload field census (read symbol.ms during impl; §6.1 list is
  from consumers, verify against the definition).
- Macro census: does std export any macros at all?
- Type pointer-identity audit (any pointer-keyed caches in checker/mono).
- `ExtMethod.fnType` exact shape.

### 6.9 Census (measured 2026-09-01, probe `preludeCensus.ms`, untracked)

551 symbols in the prelude base ctx (427 exported). AST-carrying subset:

| root | syms | exported | generic | fnBodies |
|---|---|---|---|---|
| buffer | 138 | 70 | 0 | **137** |
| struct | 49 | 24 | **27** | 9 |
| math | 35 | 33 | 0 | 33 |
| array/string/promise/system | ~71 | | 8 | 53 |
| (sub-modules: json/fetch trees + meta) | 223 | 217 | 9+ | 173 (+7 enums, **4 macros**, 23 defP) |
| TOTAL | 551 | 427 | 44 | 428 |

Conclusion: virtually every root carries AST (bodies for the Raiser walker,
generics for mono) — a body-less symbol pack would break generic calls and
macro expansion. **Full AST serialization = the IC trap → NOT v1.** Do A0
(pure transform cache) first; the semantic pack (A1) only pays for the
remaining ~150-200 ms and must wait for the lazy-body design (§6.4).

## 7. Stale notes to fix when touching transam/CLAUDE.md

§10 says "generics not monomorphized yet", "no macro system yet",
"batch doesn't need persistence" — all outdated (mono + @comptime exist;
persistence is now Phase A).

## 8. Progress tracker

- [x] Phase 0 — decompose the 702 ms — DONE 2026-09-01 (§1.2). Includes the
      inlineHeaderImports measurement (175 ms loader-half, timed inside the
      function; accumulator + `graphLoad:` print, off by default).
- [x] Phase A design note — DONE, §6 + census §6.9 (pack feasibility:
      551 syms / 427 exported / 44 generic / 428 fn bodies / 4 macros /
      7 enums — AST serialization is NOT v1; A0 first)
- [x] Phase A0 impl + verify — DONE 2026-09-01. Disk cache for
      `inlineHeaderImports` (cache.ms Layer 5 + loader wrapper via injected
      callbacks — layering: loader can't import compiler/cache because
      checker/context imports module/graph; same cycle-breaker pattern as
      parser/callbacks.ms). Dep recording threaded cparse→cimport→emit so
      user headers and #include transitive reads/absences are verified on
      every hit; stamped-tree (runtime/, vendor/) deps skip re-verify.
      Kill-switch `MSC_NO_HEADER_CACHE=1`; only error-free, output≠source
      runs are stored; global dir `~/.metascript/cache/headers/` with the
      same VERSION:stamp marker GC as objects/. Measured (011-truthy,
      mscW2 self-host): inlineHeader 152→6.8 ms, preludeMods 205→60 ms,
      warm build wall 1.5 s→1.1 s (−27%). Verified: emitted-C byte-identical
      (0 new fp-keyed .c across ON/OFF/kill-switch), header-edit → miss →
      heal → hit chain, suite 3523/3523, parity 776/0/3, SAN 161/0/1.
      Note: single-slot last-writer-wins — editing a header flips its one
      entry; a flip back needs one recompute run before hitting again
      (observed, benign).
- [x] Phase A1 impl — ATTEMPTED 2026-09-02, PARKED behind MSC_PRELUDE_PACK=1
      (opt-in, default off). What was built: checker/preludePack.ms (symbol/
      type/extension/converter/directive serializer, ~200KB pack, reader
      ~7ms; key = toolStamp|stdTreeHash|backendExt sharing the object cache's
      memoized stamp via registered callback) + lazy materializer in
      checkPass (graph-donor first: orchestrator P2 registers every std
      module ctx BEFORE user modules, so declNode recovery is one
      lookupModuleCtx away; parse+re-check fallback for graph-less paths)
      + ensure hooks at the 6 downstream declNode/defaultParams read sites.
      What it achieved when working: prelude block 146ms → 14ms (−131ms),
      suite green. Why parked: the identity traps §6.9 predicted — extension
      registry syms are SEPARATE objects from scope syms (two S-rows), the
      same-name extensions across receivers cross-patch (Map.set vs
      HashMap.set), donor registries dedup back onto the very pack objects
      being patched (registerExtension's logical-identity dedup), and extern
      extensions never carry declNode. Three fix rounds each surfaced the
      next class; corpus went 54→66 fails. Net lesson: a serialize+patch
      prelude context needs the registry/symbol graph treated as ONE
      identity-consistent closure, not scope+registry walks — i.e. the real
      fix is TransAm-shaped (Phase B) or "serialize enough to never
      materialize". All infra kept behind the opt-in flag; zero effect on
      default builds (verified: suite 3531/3531, parity 784/0/3, SAN
      162/0/1 with mscW10, pack off). Discovered en route (pre-existing,
      NOT pack-related): buildPreludeContext's baseCtx silently carried 4
      "Property 'set' does not exist on type 'Map'" errors that orchestrator
      ignored — FIXED 2026-09-03 (`bacbdab6`): the shared prelude scope lets
      a later module's overload land on an already-Shaped primary, where
      ensureShaped's early-return skipped it; shaping now drains the whole
      chain. Full story: docs/NIM-REF.md "Symbol identity" section.
- [x] Phase A1 v2 impl + verify — DONE 2026-09-03, DEFAULT ON. The pack is a
      SELF-CONTAINED closure (Nim ast2nif / rustc rmeta model): one
      index-linked object graph of Symbols, Types AND Nodes (declNode,
      defaultParams, macro bodies, nodeType/resolvedSym/typeExpr refs) — no
      donor contexts, no lazy materializer, no downstream ensure-hooks;
      identity falls out of "one row = one object". Numbers (danger build):
      closure 3390 syms / 4320 types / 28014 nodes → 2.0 MB; HIT prelude
      117→88 ms (load 81: split 3 / rows 48 / links 15; key 7). Two reader
      traps fixed en route, both now documented in-code: (1) the pack is
      FORCED ASCII (\xHH escapes) because char-indexed string ops re-walk
      UTF-8 on non-ASCII input — a char-indexed scan of the 2 MB blob was
      quadratic and hung the loader outright (97 std files carry non-ASCII);
      (2) empty-list marker is "" not "0" — a bare "0" is a REAL one-element
      list [nodes[0]]. Fast paths: unescapeP early-out (most fields carry no
      escape), charCodeAt digit accumulation for int lists, slice-based CSV
      split (the old char-concat builder allocated per character). Verified:
      unit 644/644, std/process warm 352/352 (the v1 killer), emitted-C
      ON≡OFF (single fingerprint reuse), suite 3531/3531, corpus parity
      814/0/0, SAN 167/0/0 — all with the pack hot. Economics: re-measured
      2026-09-03 on HEAD post-merge (9-round interleaved ON/OFF, 011-truthy,
      unique --output each round): prelude 87.0 ms ON vs 136.3 ms OFF
      (−49.3 ms), graph load+check 393.0 vs 439.7 ms, total 1097 vs
      1152 ms. The earlier "−29 ms" claim used a warmer OFF baseline;
      −49 ms is the honest current number. A binary format is the next
      lever if more is needed (ASCII decode is ~80 of the 87 ms).
- [ ] Phase A2 impl — loader seeds std graph from pack dep-lists (writer/
      reader/wiring/kill-switch) — NOTE: A2's dep-list section needs NO
      symbols/AST, so it does NOT inherit A1's identity traps; still viable
      next.
- [ ] Phase A verify — ladder + cold/warm/flip matrix
- [ ] Phase B — batch pipeline on TransAm
- [ ] Phase C — `--batch` CLI + corpus runner integration
- [ ] Parallel: checker hot-loop profile (`checkCallExpr` 44 ms / n=3856;
      `node.ms` 114 ms transform — both now measured, both worth a look)
- [x] 2026-09-01 — measurement + root cause + architecture decision (this doc)
- [x] 2026-09-01 — prerequisite plumbing already landed: vendor in
      toolchainStamp, marker-GC of global cache, atomic object cache (e9ba1ef2)
