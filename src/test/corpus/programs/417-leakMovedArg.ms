// @maxrss: 40
// @stdout: leak-moved-arg done
// @serial
// note: FIXED (analyzer inject.ms processMove honored the consuming position's
// DrcMode). MS callee convention is "params are borrows, caller owns" (ea38c2a —
// no sink params; the only consumed positions are the hardcoded runtime sinks:
// msArrayPush / msFutureCompleteT / msMsgComplete* / msSpawnInto). But an explicit
// `move` at a call-argument position unconditionally forced the inner arg into
// Consumed: destructiveMoveVar → msPtrWasMoved(source) → the caller's scope-exit
// destroy was skipped, while the callee (a borrow) never destroys params — the
// value ended up with NO owner on either side. Measured: exactly 1 leaked ref per
// moved RC argument, on EVERY call shape (plain function, awaited actor CALL), for
// refs and strings alike (ledger: alloc=100 destroy=0 at 100 iterations; control
// probes without `move` balanced 100/100). The implicit last-read path was always
// correct (raw pass + caller msDecref) — the fix makes `move x` at a borrow
// position compile identically; `move` keeps only its checker meaning (sendable
// crossing + dead binding). Reference parity: the call-arg loop decides the mode
// from the CALLEE (sinkArg only for sink params / spawn handoff) — an explicit
// move never overrides the position; MS's SEND-class actor handoff keeps Consumed
// (SymbolFlag.ActorProxy + awaitLower's AwaitHandle park marker), the analog of
// inSpawn>0. Program: 1M fn-move (ref), 1M fn-move (heap string), 300k awaited
// actor CALL with move — flat RSS proves the caller-side destroy runs. The
// fire-and-forget SEND + move shape is pinned separately (418): its actor-side
// release is a PARALOCK amendment still pending.
interface Box { v: int32; }
function takeRef(b: Box): int32 { return b.v; }
function takeStr(s: string): int32 { return s.length; }
actor Sink {
	seen: int32 = 0;
	takeActor(b: Box): int32 { this.seen = this.seen + b.v; return b.v; }
	get(): int32 { return this.seen; }
}
function main(): void {
	let r = 0;
	for (let i = 0; i < 1000000; i = i + 1) {
		const b: Box = { v: 1 };
		r = r + takeRef(move b);
	}
	for (let i = 0; i < 1000000; i = i + 1) {
		const s = "x" + i.toString();
		r = r + takeStr(move s);
	}
	const sink = new Sink();
	for (let i = 0; i < 300000; i = i + 1) {
		const b: Box = { v: 2 };
		const t = await sink.takeActor(move b);
		r = r + t;
	}
	const total = await sink.get();
	if (total !== 600000) { console.log("FAIL actor sum"); process.exit(1); }
	console.log(`leak-moved-arg done r=${r}`);
}
main();
