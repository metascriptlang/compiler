// @maxrss: 40
// @stdout: leak-switch-arm-temp acc=
// The DRC half of this guard is C-only (js has no refcounting), but the js lane
// still earns its place: it re-derives `acc` through an independent backend, so
// a lowering bug that changed which arms run breaks parity even where the
// ledger cannot see it.
//
// leak-switch-arm-temp — SWITCH-LOWERED match arm variant of 609/610.
//
// A fresh call result passed inline as a call arg inside an expression-form
// match arm, where the match subject is int32 → matchLower emits a C switch
// (not the if-chain that number subjects get). The analyzer captures the arg
// into $tmp and generates cleanup, but processSwitchCase used to append that
// cleanup AFTER the arm's return — dead code, so every arm execution leaked
// one VData (json parser leaked 1 JsonValueData per parsed true/false/null
// this way). Fix: processSwitchCase honors scope.needsTry and wraps the case
// body in try/finally, same as processBlockBody. If-chain lowering was always
// clean — flipping `ch` to `number` hides the bug. Arms MUST interleave
// 116/110: the clean `_` arm keeps destroy>0 so the runner's ledger check
// engages — destroy==0 (total leak) is its documented blind spot.

enum VKind { Null, Bool }

type VData = match (kind: VKind) {
	VKind.Null => {},
	VKind.Bool => { boolVal: boolean },
};

type V = Ref<VData>;

interface POk { node: V; pos: number; }
type PRes = Result<POk, string>;

function vBool(b: boolean): V { return { kind: VKind.Bool, boolVal: b }; }
function vNull(): V { return { kind: VKind.Null }; }

function parseLit(pos: number, value: V): PRes {
	if (pos < 0) return Result.err("bad");
	return Result.ok({ node: value, pos: pos + 4 });
}

function parseValue(ch: int32, pos: number): PRes {
	return match (ch) {
		116 => parseLit(pos, vBool(true)),
		_ => parseLit(pos, vNull()),
	};
}

function main(): void {
	let acc = 0;
	for (let i = 0; i < 100000; i = i + 1) {
		const ch: int32 = (i % 2) == 0 ? 116 : 110;
		const r = parseValue(ch, i % 100);
		if (r.ok) { acc = ((acc + r.value.pos) % 1000) as int32; }
	}
	console.log(`leak-switch-arm-temp acc=${acc}`);
}
main();
