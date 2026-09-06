// Parity program — variant values widening into a structural DU union at
// every fit position (bug099): var init, reassign, plain call arg, return,
// Result.ok generic inference. Heap-string payloads churned in a loop so the
// SAN ledger sees real copy/destroy traffic on the widen path; the aliased
// case reads the source AFTER the widen to pin copy (not move) semantics.

interface Tag { kind: "tag"; label: string; }
interface Num { kind: "num"; label: string; }
type Entry = Tag | Num;

function mkTag(i: int32): Tag {
	return { kind: "tag", label: "t-" + i.toString() };
}

function mkNum(i: int32): Num {
	return { kind: "num", label: "n-" + i.toString() };
}

function describe(e: Entry): string {
	if (e.kind == "tag") {
		return "tag:" + e.label;
	}
	return "num:" + e.label;
}

function pick(i: int32): Entry {
	if (i % 2 == 0) {
		const t: Tag = mkTag(i);
		return t;
	}
	const n: Num = mkNum(i);
	return n;
}

function decode(i: int32): Result<Entry, string> {
	if (i < 0) {
		return Result.err("negative");
	}
	const t: Tag = mkTag(i);
	return Result.ok(t);
}

function main(): void {
	let tags = 0;
	let nums = 0;
	for (let i = 0; i < 50000; i += 1) {
		const e = pick(i);
		if (e.kind == "tag") {
			tags += 1;
		} else {
			nums += 1;
		}
	}
	console.log("tags=" + tags.toString() + " nums=" + nums.toString());

	const t: Tag = mkTag(7);
	const widened: Entry = t;
	console.log("aliased=" + describe(widened) + " orig=" + t.label);

	let cur: Entry = mkNum(1);
	cur = mkTag(2);
	console.log("reassign=" + describe(cur));

	console.log("arg=" + describe(mkTag(3)));

	const ok = decode(11);
	if (ok.ok) {
		console.log("res=" + describe(ok.value));
	}
	const bad = decode(0 - 1);
	if (!bad.ok) {
		console.log("err=" + bad.error);
	}
}

main();
