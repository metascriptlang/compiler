// nim-guard: shrinking a `Ptr<void>[]` never releases the evicted elements
//
// INVARIANT (Nim): seqs_v2.nim:210-221 `shrink` resets evicted elements only when
//   `not supportsCopyMem(T)`; a `ptr` element is copyMem-trivial, so shrinking lowers the
//   length and touches nothing. NIM-REF AN-15.
//
// WHAT IT CATCHES: `arr.length = n` / `setLength` on a Ptr<void>[] lowered to the counted
//   eviction helper (nativeLower evictHelperName → msRefArraySetLen), which decrefs every
//   evicted address the array never counted.
//
// RED MEANS a Probe was destroyed while still owned (the count below, or the ledger's
//   DOUBLE-DESTROY). Run /trace-nim on evictHelperName.
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

function main(): int32 {
	const owners: Probe[] = [];
	for (let i = 0; i < COUNT; i++) owners.push(new Probe(i as int32));

	const addrs: Ptr<void>[] = [];
	for (let i = 0; i < owners.length; i++) addrs.push(owners[i] as Ptr<void>);
	addrs.length = COUNT / 2;
	if (destroyed != 0) {
		console.log(`GUARD RED: halving a Ptr<void>[] destroyed ${destroyed} owned probes`);
		return 1;
	}
	addrs.setLength(0);
	if (destroyed != 0) {
		console.log(`GUARD RED: clearing a Ptr<void>[] destroyed ${destroyed} owned probes`);
		return 1;
	}
	for (let i = 0; i < COUNT; i++) {
		if (owners[i].tag != (i as int32)) {
			console.log(`GUARD RED: owner ${i} reads tag ${owners[i].tag}`);
			return 1;
		}
	}
	if (addrs.length != 0) {
		console.log(`GUARD RED: length ${addrs.length}`);
		return 1;
	}
	console.log("GUARD-OK");
	return 0;
}

const guardRc = main();
if (guardRc != 0) process.exit(guardRc);
