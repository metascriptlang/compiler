import { createRequire } from "node:module";
import { bench } from "../../harness.mjs";

const n = createRequire(import.meta.url)(process.env.NEON_ADDON);
let sink = 0;
const s16 = "hello wasm world";
const xs = [];
for (let i = 0; i < 1000; i++) xs.push(Math.fround(i * 0.25));
const fx = new Float32Array(xs);

bench("add x1000", 0, () => { let s = 0; for (let i = 0; i < 1000; i++) s = n.add(i & 1023, 7); sink += s; });
bench("add64 x1000", 0, () => { let s = 0n; for (let i = 0; i < 1000; i++) s = n.add64(BigInt(i), 7n); sink += Number(s); });
bench("strLen16 x1000", 0, () => { let s = 0; for (let i = 0; i < 1000; i++) s += n.strLen(s16); sink += s; });
bench("echo16 x1000", 0, () => { let s = 0; for (let i = 0; i < 1000; i++) s += n.echo(s16).length; sink += s; });
bench("mid x1000", 0, () => { let s = 0; for (let i = 0; i < 1000; i++) s += n.mid({ x: i, y: 2 }).x; sink += s; });
bench("sumVec 1k Array", 0, () => { sink += n.sumVec(xs); });
bench("sumSpan 1k Float32Array", 0, () => { sink += n.sumSpan(fx); });
bench("scaleSpan 1k Float32Array", 0, () => { n.scaleSpan(fx, 1); });
const box = n.makeBox(1000);
bench("scaleBox 1k held by callee", 0, () => { n.scaleBox(box, 1); });
bench("makeVec 1k", 0, () => { sink += n.makeVec(1000).length; });
bench("callback 1k", 0, () => { sink += n.each(1000, (k) => k & 7); });
bench("primes 2M", 0, () => { sink += n.primes(2000000); });
if (sink === 0) console.log("sink unused");
