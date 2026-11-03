// @skip-js: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: base end
// @stdout: destroy R 9
// @stdout: destroy R 0
// @stdout: string end
// @stdout: destroy S 9 [xxx]
// @stdout: destroy S 0 []
// @stdout: keep 9
// @stdout: destroy R 9
// @stdout: sinkArg end
// @stdout: destroy R 0
// @stdout: bindMove end
// @stdout: destroy R 9
// @stdout: destroy R 0
// @stdout: literal end
// @stdout: destroy R 9
// @stdout: neighbour end
// @stdout: destroy R 8
struct R { id: int32; }
function onDestroy(this r: R): void { console.log(`destroy R ${r.id}`); }
function mk(id: int32): R { return { id: id }; }

struct S { id: int32; s: string; }
function onDestroy(this x: S): void { console.log(`destroy S ${x.id} [${x.s}]`); }
function mkS(id: int32): S { return { id: id, s: "x".repeat(3) }; }

struct Holder { r: R; tag: string; }
struct SHolder { s: S; tag: string; }

function keep(sink r: R): void { console.log(`keep ${r.id}`); }

function base(): void { const t = mk(9); const h: Holder = { r: t, tag: "t" }; console.log("base end"); }
function withString(): void { const t = mkS(9); const h: SHolder = { s: t, tag: "t" }; console.log("string end"); }
function sinkArg(): void { const t = mk(9); keep(t); console.log("sinkArg end"); }
function bindMove(): void { const t = mk(9); const y = move t; console.log("bindMove end"); }
function literal(): void { const t: R = { id: 9 }; const h: Holder = { r: t, tag: "t" }; console.log("literal end"); }
function neighbour(): void { const h: Holder = { r: mk(8), tag: "t" }; console.log("neighbour end"); }

base();
withString();
sinkArg();
bindMove();
literal();
neighbour();
