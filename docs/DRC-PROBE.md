# Debug Technique: Nim ↔ MetaScript C-emit comparison

> Discovered the DRC array-overwrite leak (2026-05-16) that OOM'd Lightcube
> `/health` at 10K rps in ~3 minutes. Hours of analyzer source reading were
> outperformed in 5 minutes by this twin-probe technique. **Always reach for
> this before reading `src/analyzer/inject.ms` for a DRC question.**

When you suspect a MetaScript codegen or DRC analyzer bug, **do not read more
analyzer source first** — write twin minimal programs in MS and Nim with the
exact same pattern, emit C from both, and diff the hot loop side-by-side.
This is the single most leveraged debug move available for codegen-level bugs.

The `/trace-nim` skill wraps this workflow; this file is the reference detail.

## Why Nim specifically

- Nim is the closest production-tier reference for MS's DRC model. Both
  inject `=destroy` / `=copy` / `=sink` / `wasMoved` hooks at a post-check
  AST pass via `moveOrCopy`-style dispatch.
- Nim ships ARC (`--gc:arc`) and ORC (`--gc:orc`) modes that map almost
  1:1 to our `--gc=drc` semantics.
- Nim's `~/projects/nim/compiler/injectdestructors.nim` is the closest
  analog to our `src/analyzer/inject.ms` — the same algorithm in a
  battle-tested form. When MS deviates from Nim, the deviation is
  usually the bug.
- Differences in emitted C are **load-bearing, not stylistic**. If Nim
  emits a per-type `=sink` helper and MS emits an inline
  `save → assign → incref → destroy` pattern, that's a real divergence
  to investigate — not a coincidence.

## The recipe

```bash
mkdir -p /tmp/drc-probe && cd /tmp/drc-probe

# 1. Twin probes — same shape, same pattern, ~20 LOC each.

cat > probe.ms <<'EOF'
interface Heavy { buf: string; }
function makeHeavy(): Heavy {
    let s = "x"; let i = 0;
    while (i < 12) { s = s + s; i = i + 1; }
    return { buf: s };
}
function main(): void {
    const arr: Heavy[] = new Array(10);
    let n = 0;
    while (n < 10) { arr[n] = makeHeavy(); n = n + 1; }
    let m = 0;
    while (m < 100000) { arr[m % 10] = makeHeavy(); m = m + 1; }
}
main();
EOF

cat > probe.nim <<'EOF'
import strutils
type Heavy = ref object
  buf: string
proc makeHeavy(): Heavy = Heavy(buf: "x".repeat(4096))
proc main() =
  var arr: array[10, Heavy]
  for i in 0..<10: arr[i] = makeHeavy()
  for m in 0..<100000: arr[m mod 10] = makeHeavy()
main()
EOF

# 2. Emit C from both.
msc build probe.ms --passC="-O0" --output=probe-ms
nim c --gc:arc -d:release --nimcache:./nim-cache -o:probe-nim probe.nim

# 3. Run both, measure RSS — first signal of divergence.
./probe-ms & P=$!; sleep 0.5; ps -p $P -o rss=
./probe-nim & P=$!; sleep 0.5; ps -p $P -o rss=

# 4. Diff the hot loop body in each emitted C.
sed -n '/^void main_/,/^}/p' out/debug/probe.c
sed -n '/main__probe/,/^}/p' nim-cache/@mprobe.nim.c
```

## What to read in the output

| Symbol in emitted C | Means |
|---|---|
| Nim `eqsink___...(&dest, src)` | Per-type sink op — atomic destroy-then-store |
| Nim `nimDecRefIsLast` then `nimRawDispose` | Decref + conditional free in one op |
| Nim's `passthrough` body has `eqcopy___(&result, h_p0); return result;` | Nim convention: callee-side incref on ref returns |
| MS inlined `save = dest; dest = src; msIncref(dest); msDecref(save);` | The analyzer's pattern — this is where the 2026-05 leak hid |
| MS's `passthrough` body has bare `return h;` | MS convention: callee returns rc=0, caller takes ownership |
| Difference in calling convention → caller-side incref logic must differ | Trace RC by hand if uncertain |

## Calibrated assumptions worth memorising

- **MS DRC convention**: `msAlloc` returns objects at `rc=0` meaning
  "sole owner". `msDecRefIsLast` returns `true` when `rc==0` (before
  decrement) — caller frees. `incref` bumps `rc` so `rc=N` means
  "N+1 owners".
- **Nim DRC convention**: objects allocated at `rc=1` meaning "sole owner".
  `nimDecRefIsLast` returns `true` when `rc==1` (before decrement).
  `nimIncRef` bumps so `rc=N` means "N owners". Convention is **offset
  by 1 from MS** — both are correct, do not confuse when porting patterns.
- **Nim emits per-type `=sink` ops via destructorLifting**; MS inlines
  the pattern at every assignment site. Both are valid, but a per-type
  op makes "decref-and-maybe-free old + raw store new" atomic, which
  matches `=sink` semantics. An inline pattern with a defensive
  `msIncref(dest)` after the store accidentally implements `=copy`
  semantics on what should be `=sink` — exactly the 2026-05 bug.

## Anti-patterns that consume the most time

- **Reading `src/analyzer/inject.ms` trying to predict what it emits.**
  Thousands of lines of intricate logic. Emit and read; do not predict.
- **Building probes with `--release`.** LLVM DCE's tiny probes that don't
  escape, hiding leaks. Use `--passC="-O0"` for honest measurements.
  (2026-05-16: lost 20 min to this — probe with `let x: Heavy = ...; while
  ... x = makeHeavy(); ...` and `--release` showed RSS=32 KB, suggesting
  no leak. Rebuilt with `-O0` and got 153 MB peak. Same bug, just masked
  by LLVM escape analysis.)
- **Empty `{}` literals.** Won't surface string-payload leaks. Use
  realistic types (string-bearing interface) so allocations are large
  enough to dominate RSS noise.
- **`--gc:orc` for the Nim side.** ORC adds cycle-collection scaffolding
  that obscures the core RC pattern. Use `--gc:arc` for the cleanest
  comparison — only switch to ORC when probing cycle semantics.
- **Nim module names cannot contain `-`.** Use underscores (`probe_aliased.nim`).
- **Stopping after the first probe.** The 2026-05 case needed three:
  - Array (`arr[i] = call()`) — first leak signal
  - Identifier (`x = call()`) — would have leaked too but `--release` DCE
    hid it; `-O0` revealed it
  - MemberExpr (`obj.field = call()`) — confirmed the bug is universal
    across LHS kinds

  Build all three LHS shapes when you suspect `moveOrCopy` is wrong —
  different branches of the dispatch may emit differently.
- **Aliased case `x = passthrough(x)`.** A separate probe — RHS returns
  the same ref it received. Tests whether the analyzer's defensive
  incref is hiding a UAF (it does — without the incref, this case UAFs;
  with the incref, the common fresh-call case leaks). The Nim probe
  for the same pattern reveals the convention difference: Nim
  callee-increfs ref returns, MS doesn't.

## When to use this playbook

Whenever a user (or you) suspects "X leaks / UAFs / crashes and I can't
tell if it's my code or MS" **and** the issue smells like RC accounting,
ownership transfer, or anything involving `=destroy` / `=copy` /
`=sink` / `wasMoved` — **before reading analyzer source**, run this
recipe. The 5 minutes it costs beats every other debugging path for
codegen-level bugs.

When the symptom is platform-specific (e.g. only Linux leaks), the
recipe is even more critical: the divergence is almost always a
code-path *trigger*, not platform-specific codegen. The probe tells
you which.
