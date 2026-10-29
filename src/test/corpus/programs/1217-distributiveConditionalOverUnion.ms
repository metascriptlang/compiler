// @stdout: lib b ea5 b3
type Pair = match (ok: boolean) { true => { value: string }, false => { error: string } };
type Ex<T, U> = T extends U ? T : never;
type OkP = Ex<Pair, { ok: true }>;
function mk(g: boolean): Pair { return g ? { ok: true, value: "lib" } : { ok: false, error: "no" }; }
function useOk(x: OkP): string { return x.value; }
enum K { A, B }
type Sh = match (k: K) { K.A => { a: int32 }, K.B => { b: string } };
type OnlyA = Ex<Sh, { k: K.A }>;
function mkSh(x: boolean): Sh { return x ? { k: K.A, a: 5 } : { k: K.B, b: "z" }; }
function useA(x: OnlyA): int32 { return x.a; }
type L = "a" | "b" | "c";
const q: Ex<L, "a" | "b"> = "b";
const p = mk(true);
const s = mkSh(true);
let out = "";
if (p.ok) out = useOk(p);
let outA = "";
if (s.k === K.A) outA = `ea${useA(s)}`;
const r: Exclude<L, "a" | "c"> = "b";
const n: Extract<1 | 2 | 3, 1 | 3> = 3;
console.log(out, q, outA, `${r === "b" ? "b" : "?"}${n}`);
