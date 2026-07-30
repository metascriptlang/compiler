// Parity program — refcounted-string churn shapes, with output reduced to
// checksums so it stays byte-comparable while the heap traffic underneath is
// heavy. On the C lanes drc/orc/danger this exercises the DRC hook placement
// (overwrite a live element, drop a returned value unread, unwind mid-build);
// on the san lane the same program becomes a leak and double-free probe for
// free. Bounds are fixed and small: it must stay honest under ASan, not stress
// RSS (615/627 own the RSS axis).

interface Holder { name: string; tag: string; }

function makePart(i: int32): string {
	return "part-" + i.toString() + "-payload";
}

function relay(s: string): string {
	return s + "!";
}

function dropUnread(i: int32): void {
	makePart(i);
	relay("x");
}

function buildOrThrow(i: int32): string {
	const head = makePart(i);
	if (i % 7 === 3) { throw "boom-" + head; }
	return head + "-ok";
}

function main(): void {
	let lenSum = 0;

	for (let i = 0; i < 2000; i = i + 1) {
		const s = makePart(i);
		lenSum = (lenSum + s.length) % 1000003;
	}
	console.log("loopBuild=" + lenSum.toString());

	for (let i = 0; i < 2000; i = i + 1) { dropUnread(i); }
	console.log("dropUnread=done");

	let relaySum = 0;
	for (let i = 0; i < 2000; i = i + 1) {
		relaySum = (relaySum + relay(makePart(i)).length) % 1000003;
	}
	console.log("relay=" + relaySum.toString());

	const slots: string[] = [];
	for (let i = 0; i < 8; i = i + 1) { slots.push(makePart(i)); }
	for (let i = 0; i < 2000; i = i + 1) { slots[i % 8] = makePart(i); }
	let slotSum = 0;
	for (const s of slots) { slotSum = slotSum + s.length; }
	console.log("arrayEvict=" + slotSum.toString());

	const h: Holder = { name: "init", tag: "t" };
	for (let i = 0; i < 2000; i = i + 1) {
		h.name = makePart(i);
		h.tag = h.name.slice(0, 4);
	}
	console.log("fieldOverwrite=" + h.name.length.toString() + "," + h.tag);

	let self = "ab";
	for (let i = 0; i < 8; i = i + 1) { self = self + self; }
	console.log("selfAppend=" + self.length.toString());

	let sep = "x";
	for (let i = 0; i < 5; i = i + 1) { sep = sep + "-" + sep; }
	console.log("selfSep=" + sep.length.toString());

	let tri = "Q";
	for (let i = 0; i < 4; i = i + 1) { tri = tri + tri + tri; }
	console.log("selfThrice=" + tri.length.toString());

	let tpl = "z";
	for (let i = 0; i < 4; i = i + 1) { tpl = `${tpl}${tpl}-`; }
	console.log("selfTemplate=" + tpl.length.toString());

	let caught = 0;
	let okLen = 0;
	for (let i = 0; i < 700; i = i + 1) {
		try {
			okLen = (okLen + buildOrThrow(i).length) % 1000003;
		} catch (e) {
			caught = caught + 1;
		}
	}
	console.log("unwind caught=" + caught.toString() + " okLen=" + okLen.toString());

	const prefix = "cap";
	const tagIt = (n: int32): string => prefix + "-" + n.toString();
	let capSum = 0;
	for (let i = 0; i < 2000; i = i + 1) { capSum = (capSum + tagIt(i).length) % 1000003; }
	console.log("closure=" + capSum.toString());

	const nested: string[][] = [];
	for (let i = 0; i < 4; i = i + 1) {
		const inner: string[] = [];
		for (let j = 0; j < 4; j = j + 1) { inner.push(makePart(i * 4 + j)); }
		nested.push(inner);
	}
	let nestSum = 0;
	for (const row of nested) { for (const s of row) { nestSum = nestSum + s.length; } }
	console.log("nested=" + nestSum.toString());
}
main();
