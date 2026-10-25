// guard: copying a counted array through a spread or a destructuring rest leaves its elements owned
//
// INVARIANT: each element pushed into the copy is a sink of one new count; the source keeps its
//   own, so the copy and the source drop independently.
//
// WHAT IT CATCHES: the lowered push (`msGenericArrayPush(arr, sink value: Ptr<void>)`) read as an
//   uncounted slot because its formal is an erased pointer. The element is then copied and
//   destroyed at scope end while the push keeps it, so every copy costs the source one count.
//   Spread and destructuring rest both lower through that push.
//
// RED MEANS a Probe was destroyed while still owned (the count below, or the ledger's
//   DOUBLE-DESTROY).
//
// Signalling via the exit code: an uncaught throw exits 0 on the C backend.
//
// GUARD-JS

let destroyed: int32 = 0;

class Probe {
	tag: int32;
	constructor(tag: int32) { this.tag = tag; }
	onDestroy(): void { destroyed += 1; }
}

const COUNT: int32 = 16;

function spreadCopy(a: Probe[], b: Probe[]): Probe[] {
	return [...a, ...b];
}

function restCopy(a: Probe[]): int32 {
	const [, ...rest] = a;
	return rest.length as int32;
}

function main(): int32 {
	const left: Probe[] = [];
	const right: Probe[] = [];
	for (let i = 0; i < COUNT; i++) {
		left.push(new Probe(i as int32));
		right.push(new Probe((COUNT + i) as int32));
	}
	let copied = 0;
	for (let round = 0; round < 8; round++) {
		copied += spreadCopy(left, right).length;
		copied += restCopy(left);
	}
	if (destroyed != 0) {
		console.log(`GUARD RED: dropping spread and rest copies destroyed ${destroyed} owned probes`);
		return 1;
	}
	for (let i = 0; i < COUNT; i++) {
		if (left[i].tag != (i as int32) || right[i].tag != ((COUNT + i) as int32)) {
			console.log(`GUARD RED: owner ${i} reads tags ${left[i].tag} ${right[i].tag}`);
			return 1;
		}
	}
	if (copied != (COUNT * 3 - 1) * 8) {
		console.log(`GUARD RED: copied ${copied}`);
		return 1;
	}
	console.log("GUARD-OK");
	return 0;
}

const guardRc = main();
if (guardRc != 0) process.exit(guardRc);
