// optimizer.nim wasMovedDestroyPair: wasMoved(x); destroy(x) is elided unless a call that can raise lies between; JS runs no struct hooks, so no GUARD-JS lane.

struct R { id: int32; name: string; }
struct Holder { r: R; tag: string; }

const log: string[] = [];

function onDestroy(this x: R): void { log.push(x.id.toString()); }
function mk(n: int32): R { return { id: n, name: "n" }; }

function quiet(): void {
	const t = mk(4);
	const h: Holder = { r: t, tag: "t" };
}

function raisingAfter(): void {
	const t = mk(9);
	const h: Holder = { r: t, tag: "t" };
	log.push("end");
}

function callResult(): void {
	const h: Holder = { r: mk(8), tag: "t" };
}

function raisingBefore(): void {
	const t = mk(7);
	log.push("mid");
	const h: Holder = { r: t, tag: "t" };
}

quiet();
log.push("|");
raisingAfter();
log.push("|");
callResult();
log.push("|");
raisingBefore();

const got = log.join(",");
if (got == "4,|,end,9,0,|,8,|,mid,7,0") {
	console.log("GUARD-OK");
} else {
	console.log("GUARD-RED " + got);
	process.exit(1);
}
