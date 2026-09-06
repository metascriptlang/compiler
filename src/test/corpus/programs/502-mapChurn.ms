// Parity program — ordered Map<K,V> churn: set/delete/overwrite cycles.
// The ordered Map promises insertion-order iteration on BOTH backends
// (C order-preserving table in std/core/struct.ms, js native Map), so
// iterated prints are legal UNSORTED here — including the re-insert rule:
// delete then set moves the key to the END on both.

function main(): void {
	const m = new Map<string, string>();
	for (let round = 0; round < 3; round += 1) {
		for (let i = 0; i < 500; i += 1) {
			m.set("k" + i.toString(), "r" + round.toString() + "v" + i.toString());
		}
		for (let i = 0; i < 500; i += 3) {
			m.delete("k" + i.toString());
		}
		console.log("round=" + round.toString() + " size=" + m.size.toString());
	}

	m.delete("k1");
	m.set("k1", "back");
	const ks = m.keys();
	console.log("first=" + ks[0]);
	console.log("last=" + ks[ks.length - 1]);
	const v = m.get("k1");
	if (v != null) { console.log("k1=" + v); }

	let n = 0;
	let acc = 0;
	for (const k of m.keys()) {
		n += 1;
		acc = acc + k.byteLength();
	}
	console.log("iterCount=" + n.toString() + " keyBytes=" + acc.toString());

	m.clear();
	console.log("cleared=" + m.size.toString());
}

main();
