// @stdout: y
// @stdout: s side-effect
// @stdout: a
// @stdout: r
// @stdout: q
// @stdout: p
// @stdout: main 2
// note: modules run their top-level code in source import order, depth first, each once, as ESM does: a side-effect import between two named imports keeps its place, a module in a cycle with the entry runs before the entry, and a three-module cycle the entry is outside of runs its innermost module first. Before the fix the JS module tree (`run --target=js`, `--split`) ran a module the entry calls into ahead of earlier imports: `a` before `y`.
import { fy } from "./lib/y";
import "./lib/s";
import { fa } from "./lib/a";
import { fp } from "./lib/p";
console.log(`main ${fa(0) + fy(1) + fp(2)}`);
export function fm(n: int32): int32 { return n > 0 ? fa(n - 1) : 0; }
