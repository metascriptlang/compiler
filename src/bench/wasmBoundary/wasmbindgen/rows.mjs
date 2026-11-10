import { bench } from "../../harness.mjs";

export function runRows(w) {
	let sink = 0;
	const s16 = "hello wasm world";
	const xs = [];
	for (let i = 0; i < 1000; i++) xs.push(Math.fround(i * 0.25));
	const fx = new Float32Array(xs);

	bench("add x1000", 0, () => { let s = 0; for (let i = 0; i < 1000; i++) s = w.add(i & 1023, 7); sink += s; });
	bench("add64 x1000", 0, () => { let s = 0n; for (let i = 0; i < 1000; i++) s = w.add64(BigInt(i), 7n); sink += Number(s); });
	bench("strLen16 x1000", 0, () => { let s = 0; for (let i = 0; i < 1000; i++) s += w.strLen(s16); sink += s; });
	bench("echo16 x1000", 0, () => { let s = 0; for (let i = 0; i < 1000; i++) s += w.echo(s16).length; sink += s; });
	bench("mid x1000", 0, () => {
		let s = 0;
		for (let i = 0; i < 1000; i++) {
			const r = w.mid(new w.Point(i, 2));
			s += r.x;
			r.free();
		}
		sink += s;
	});
	bench("sumVec 1k Array", 0, () => { sink += w.sumVec(xs); });
	bench("sumSpan 1k Float32Array", 0, () => { sink += w.sumSpan(fx); });
	bench("scaleSpan 1k Float32Array", 0, () => { w.scaleSpan(fx, 1); });
	const box = new w.FBuf(1000);
	bench("scaleBox 1k held by callee", 0, () => { box.scale(1); });
	bench("makeVec 1k", 0, () => { sink += w.makeVec(1000).length; });
	bench("callback 1k", 0, () => { sink += w.each(1000, (k) => k & 7); });
	const ctr = new w.Counter(0);
	bench("method x1000", 0, () => { let s = 0; for (let i = 0; i < 1000; i++) s = ctr.bump(1); sink += s; });
	bench("field x1000", 0, () => { let s = 0; for (let i = 0; i < 1000; i++) s += ctr.n; sink += s; });
	bench("construct x1000", 0, () => { for (let i = 0; i < 1000; i++) { const c = new w.Counter(i & 1023); c.free(); } });
	bench("primes 2M", 0, () => { sink += w.primes(2000000); });
	box.free();
	ctr.free();
	if (sink === 0) console.log("sink unused");
}
