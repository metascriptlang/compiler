import { createRequire } from "node:module";
import { bench } from "../../harness.mjs";

const n = createRequire(import.meta.url)(process.env.NEON_ADDON);
let sink = 0;
// With a constant bound, Node's V8 measured wasm-bindgen's add and method rows four times slower than
// warmed (baseline.md, 2026-11-12): keep the bound a variable and the row warmed.
let calls = 1;
function benchWarmed(name, op) {
	calls = 1;
	for (let k = 0; k < 400; k++) op();
	calls = 1000;
	bench(name, 0, op);
}
const s16 = "hello wasm world";
const xs = [];
for (let i = 0; i < 1000; i++) xs.push(Math.fround(i * 0.25));
const fx = new Float32Array(xs);

benchWarmed("add x1000", () => { let s = 0; for (let i = 0; i < calls; i++) s = n.add(i & 1023, 7); sink += s; });
benchWarmed("add64 x1000", () => { let s = 0n; for (let i = 0; i < calls; i++) s = n.add64(BigInt(i), 7n); sink += Number(s); });
benchWarmed("strLen16 x1000", () => { let s = 0; for (let i = 0; i < calls; i++) s += n.strLen(s16); sink += s; });
benchWarmed("echo16 x1000", () => { let s = 0; for (let i = 0; i < calls; i++) s += n.echo(s16).length; sink += s; });
benchWarmed("mid x1000", () => { let s = 0; for (let i = 0; i < calls; i++) s += n.mid({ x: i, y: 2 }).x; sink += s; });
bench("sumVec 1k Array", 0, () => { sink += n.sumVec(xs); });
bench("sumSpan 1k Float32Array", 0, () => { sink += n.sumSpan(fx); });
bench("scaleSpan 1k Float32Array", 0, () => { n.scaleSpan(fx, 1); });
const box = n.makeBox(1000);
bench("scaleBox 1k held by callee", 0, () => { n.scaleBox(box, 1); });
bench("makeVec 1k", 0, () => { sink += n.makeVec(1000).length; });
bench("callback 1k", 0, () => { sink += n.each(1000, (k) => k & 7); });
bench("primes 2M", 0, () => { sink += n.primes(2000000); });
if (sink === 0) console.log("sink unused");
