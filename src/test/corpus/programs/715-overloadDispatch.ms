// Parity program — free-function overload dispatch binds the check-time
// winner at every call site (bug: js emitted the primary `_u0` for ALL
// call sites while C honored resolvedOverloadIdx, so `childOf(box)` ran
// the string body → undefined member reads at runtime). Heap-string
// payloads churned in a loop so the SAN ledger sees the winner bodies'
// copy/destroy traffic, not just one dispatch.

interface Box { n: int32; tagText: string; }

function childOf(s: string): Box {
	return { n: s.length, tagText: "str:" + s };
}

function childOf(b: Box): Box {
	return { n: b.n + 4, tagText: "box:" + b.tagText };
}

function childOf(i: int32): Box {
	return { n: i * 10, tagText: "int:" + i.toString() };
}

function main(): void {
	const fromStr = childOf("abc");
	console.log("str " + fromStr.n.toString() + " " + fromStr.tagText);

	const seed: Box = { n: 3, tagText: "seed" };
	const fromBox = childOf(seed);
	console.log("box " + fromBox.n.toString() + " " + fromBox.tagText);

	const fromInt = childOf(5);
	console.log("int " + fromInt.n.toString() + " " + fromInt.tagText);

	let acc: int32 = 0;
	for (let i = 0; i < 2000; i += 1) {
		const viaStr = childOf("k-" + i.toString());
		const viaBox = childOf(viaStr);
		const viaInt = childOf(i);
		acc = acc + viaBox.n + viaInt.n - viaStr.n;
	}
	console.log("acc=" + acc.toString());
}

main();
