// nim-guard: an array of `Ptr<void>` never releases its elements
//
// INVARIANT (Nim): `ptr` is trivial in every container op. liftdestructors.nim:1117-1119
//   sends tyPtr to defaultOp, forallElements (:608-619) drops the element loop when it
//   is empty, so `=destroy(seq[ptr T])` frees the payload only and `=copy` is a bulk
//   copy (:665-670). NIM-REF AN-15: the `seq[pointer]` role, held by `unknown` until
//   2026-09-28 and by `Ptr<void>` since.
//
// WHAT IT CATCHES: a local `Ptr<void>[]` destroyed or copied through the counted ref
//   family. `owner as Ptr<void>` is an uncounted address (docs/LANG.md), so the push
//   adds no count; a counted destroy then releases every owner the array merely
//   pointed at, while `owners` still holds them (std/hcr's `states` on 8496efa2).
//
// RED MEANS a Probe was destroyed while still owned (the count below, or the ledger's
//   DOUBLE-DESTROY). Run /trace-nim on the Ptr arm of classify.ms classifyArray and of
//   codegen refArrayDestroyFn.
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

const COUNT: int32 = 64;

function pointAtAll(owners: Probe[]): int32 {
	const addrs: Ptr<void>[] = [];
	for (let i = 0; i < owners.length; i++) {
		addrs.push(owners[i] as Ptr<void>);
	}
	return addrs.length as int32;
}

function copyAndDrop(owners: Probe[]): int32 {
	const addrs: Ptr<void>[] = [];
	for (let i = 0; i < owners.length; i++) {
		addrs.push(owners[i] as Ptr<void>);
	}
	const copy = addrs.slice(0);
	return (addrs.length + copy.length) as int32;
}

function main(): int32 {
	const owners: Probe[] = [];
	for (let i = 0; i < COUNT; i++) owners.push(new Probe(i as int32));

	let pointed = 0;
	for (let round = 0; round < 8; round++) pointed += pointAtAll(owners);
	if (destroyed != 0) {
		console.log(`GUARD RED: dropping a Ptr<void>[] destroyed ${destroyed} owned probes`);
		return 1;
	}
	pointed += copyAndDrop(owners);
	if (destroyed != 0) {
		console.log(`GUARD RED: copying a Ptr<void>[] destroyed ${destroyed} owned probes`);
		return 1;
	}
	for (let i = 0; i < COUNT; i++) {
		if (owners[i].tag != (i as int32)) {
			console.log(`GUARD RED: owner ${i} reads tag ${owners[i].tag}`);
			return 1;
		}
	}
	if (pointed != COUNT * 10) {
		console.log(`GUARD RED: pointed ${pointed}`);
		return 1;
	}
	console.log("GUARD-OK");
	return 0;
}

const guardRc = main();
if (guardRc != 0) process.exit(guardRc);
