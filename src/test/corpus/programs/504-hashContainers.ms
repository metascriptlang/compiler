// @xfail(esm): tree emit: prelude container class binding never imported into the referencing module
// Parity program — std collections: HashMap<K,V> / HashSet<T>.
// C = open addressing (std/core/struct.ms); JS = native Map/Set aliases
// (std/core/struct.jms — STRING-CONTRACT §5: the containers promise NO
// iteration order, so native insertion order is a permitted strengthening).
// Because no order is promised, every iterated print here is SORTED first —
// the program canonicalizes, the runner never fuzzy-matches.
// Values stay ref-typed (string): a value-type V makes get() return the
// Maybe carrier of the open G1 cluster — 010-nullable owns that xfail.

function sorted(xs: string[]): string[] {
	const out: string[] = [];
	for (const x of xs) { out.push(x); }
	for (let i = 1; i < out.length; i += 1) {
		let j = i;
		while (j > 0 && out[j] < out[j - 1]) {
			const t = out[j];
			out[j] = out[j - 1];
			out[j - 1] = t;
			j -= 1;
		}
	}
	return out;
}

function main(): void {
	const m = new HashMap<string, string>();
	m.set("alpha", "1");
	m.set("beta", "2");
	m.set("gamma", "3");
	console.log("size=" + m.size.toString());
	const hit = m.get("beta");
	if (hit != null) { console.log("get=" + hit); }
	const miss = m.get("nope");
	if (miss == null) { console.log("miss=null"); }

	m.set("beta", "2b");
	console.log("sizeAfterUpdate=" + m.size.toString());
	const upd = m.get("beta");
	if (upd != null) { console.log("updated=" + upd); }

	console.log("hasGamma=" + (m.has("gamma") ? "y" : "n"));
	console.log("delGamma=" + (m.delete("gamma") ? "y" : "n"));
	console.log("delAgain=" + (m.delete("gamma") ? "y" : "n"));
	console.log("sizeAfterDelete=" + m.size.toString());

	let ks = "";
	for (const k of sorted(m.keys())) { ks = ks + k + ","; }
	console.log("keys=" + ks);

	const s = new HashSet<string>();
	s.add("x");
	s.add("y");
	s.add("x");
	console.log("setSize=" + s.size.toString());
	console.log("hasX=" + (s.has("x") ? "y" : "n"));
	console.log("delX=" + (s.delete("x") ? "y" : "n"));
	console.log("hasXAfter=" + (s.has("x") ? "y" : "n"));
	console.log("setSizeAfter=" + s.size.toString());

	const churn = new HashMap<string, string>();
	for (let i = 0; i < 200; i += 1) {
		churn.set("k" + i.toString(), "v" + i.toString());
	}
	for (let i = 0; i < 200; i += 2) {
		churn.delete("k" + i.toString());
	}
	console.log("churnSize=" + churn.size.toString());
	const odd = churn.get("k101");
	if (odd != null) { console.log("churnHit=" + odd); }
	const even = churn.get("k100");
	if (even == null) { console.log("churnMiss=null"); }

	const feParts: string[] = [];
	m.forEach((v: string, k: string) => { feParts.push(k + "=" + v); });
	let fe = "";
	for (const e of sorted(feParts)) { fe = fe + e + ","; }
	console.log("hmForEach=" + fe);

	const seen: string[] = [];
	s.forEach((v: string) => { seen.push(v); });
	let sf = "";
	for (const e of sorted(seen)) { sf = sf + e + ","; }
	console.log("hsForEach=" + sf);

	const hl: HashMap<string, string> = { "lit": "L1" };
	const lv = hl.get("lit");
	if (lv != null) { console.log("hmLiteral=" + lv); }
}

main();
