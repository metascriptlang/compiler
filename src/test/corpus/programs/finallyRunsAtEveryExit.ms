// @stdout: exits ret 2|throw in t|throw out t|break 1|break 2|break after|catch break 1|catch break 2|catch break after|cont in 1|cont out 1|cont in 2|cont out 2|leave fin|leave later|deep in|deep out deeper|winner|kept inner|kept outer|async fin 5|async caught bad
// note: a finally runs exactly once, at the moment its try or catch is left — by return, raise, break or continue out of the catch body, by break or continue out of the try body, by a raise one call deeper — and its body runs as ordinary code: a raise in it displaces the one in flight, a try inside it keeps the flight going, an await in it suspends (the Raiser skipped catch-body exits, ran a break's finally at the next return, and let the flight win).

async function ok(): Promise<int32> { return 5; }
async function fail(): Promise<int32> { throw new Error("bad"); }

function returnFromCatch(out: string[]): int32 {
	try { throw new Error("s"); } catch (e) { return 2; } finally { out.push("ret 2"); }
}
function throwFromCatch(out: string[]): void {
	try {
		try { throw new Error("s"); } catch (e) { throw new Error("t"); } finally { out.push("throw in t"); }
	} catch (e2) { out.push(`throw out ${e2.message}`); }
}
function breakFromTry(out: string[]): void {
	let n = 0;
	while (n < 3) { n += 1; try { if (n == 2) break; } finally { out.push(`break ${n}`); } }
	out.push("break after");
}
function breakFromCatch(out: string[]): void {
	let n = 0;
	while (n < 3) { n += 1; try { throw new Error("x"); } catch (e) { if (n == 2) break; } finally { out.push(`catch break ${n}`); } }
	out.push("catch break after");
}
function continueThroughTwo(out: string[]): void {
	let n = 0;
	while (n < 2) { n += 1; try { try { continue; } finally { out.push(`cont in ${n}`); } } finally { out.push(`cont out ${n}`); } }
}
function raiseAfterLeaving(out: string[]): void {
	try {
		while (true) { try { break; } finally { out.push("leave fin"); } }
		throw new Error("later");
	} catch (e) { out.push(`leave ${e.message}`); }
}
function deeper(): void { throw new Error("deeper"); }
function raiseOneCallDeeper(out: string[]): void {
	try {
		try { throw new Error("first"); } catch (e) { deeper(); } finally { out.push("deep in"); }
	} catch (e2) { out.push(`deep out ${e2.message}`); }
}
function displaced(): string {
	try { try { throw new Error("displaced"); } finally { throw new Error("winner"); } } catch (e) { return e.message; }
}
function flightKept(out: string[]): string {
	try {
		try { throw new Error("outer"); } finally { try { throw new Error("inner"); } catch (e) { out.push(`kept ${e.message}`); } }
	} catch (e) { return e.message; }
	return "swallowed";
}
async function awaitInUnwindingFinally(out: string[]): Promise<void> {
	try {
		try { await fail(); } finally { const v = await ok(); out.push(`async fin ${v}`); }
	} catch (e) { out.push(`async caught ${e.message}`); }
}

async function main(): Promise<void> {
	const out: string[] = [];
	const r = returnFromCatch(out);
	throwFromCatch(out);
	breakFromTry(out);
	breakFromCatch(out);
	continueThroughTwo(out);
	raiseAfterLeaving(out);
	raiseOneCallDeeper(out);
	out.push(displaced());
	out.push(`kept ${flightKept(out)}`);
	await awaitInUnwindingFinally(out);
	console.log(`exits ${out.join("|")}`);
	if (r != 2) console.log("bad return");
}
main();
