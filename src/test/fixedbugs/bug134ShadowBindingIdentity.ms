// bug134 — a binding that shadows a captured name resolved through the outer
// binding's env slot
//
// Symptom:    inside a function whose closure captures a local, any LATER
//             binding spelling the same name in a nested block, an if-block or
//             a nested arrow body was rewritten into the captured binding's env
//             field. Reads returned the outer value, writes destroyed the value
//             the closure had captured, and a shadow inside a nested arrow that
//             captured nothing emitted `_envP->x` in a function with no `_envP`
//             (loud C build failure). Silent wrong values otherwise, C only —
//             the JS backend does not lambda-lift.
// Root cause: src/transform/lowering/lambdaLifting.ms keys every rewrite on the
//             binding's NAME: the capture set, the env field names, the active
//             rewrite list, and the loop redirect all compare strings, so two
//             distinct bindings sharing a name became one storage slot. The
//             reference keys captures and env fields by symbol id instead
//             (`capturedVars.incl(s.id)`, `addField` → `lookupInRecord`).
// Fix:        src/transform/lowering/lambdaLiftingRename.ms — a scope-aware
//             pre-pass renames a shadowing binding (and its references) to a
//             fresh name before capture detection, so a name identifies exactly
//             one binding. Module-scope bindings and parameters keep their
//             names; only the inner, shadowing binding is renamed.
//
// Guarded end-to-end by corpus/programs/308-closureNestedShadow.ms and
// guard/closureShadowBindingIdentity.ms.

type B134Thunk = () => int32;

function b134BlockShadowInLoop(): string {
	const fns: B134Thunk[] = [];
	const seen: int32[] = [];
	for (let i = 0; i < 3; i += 1) {
		let x = 100 + i;
		fns.push(() => x);
		{
			let x = 900 + i;
			seen.push(x);
			x = x + 1;
			seen.push(x);
		}
	}
	let out = "";
	for (const v of seen) { out = out + v.toString() + ","; }
	out = out + "|";
	for (const f of fns) { out = out + f().toString() + ","; }
	return out;
}

function b134BlockShadowNoLoop(): string {
	let x = 100;
	const f = () => x;
	let got = "";
	{
		let x = 900;
		got = got + x.toString() + ",";
		x = x + 1;
		got = got + x.toString() + ",";
	}
	return got + "cap=" + f().toString();
}

function b134ShadowInNestedArrow(): string {
	let b = 50;
	const fb = () => b;
	const inner = (): int32 => { let b = 700; return b; };
	return inner().toString() + "," + fb().toString();
}

function b134ShadowInIfBlock(): string {
	let a = 100;
	const fa = () => a;
	let got = 0;
	if (a > 0) { let a = 900; got = a; }
	return got.toString() + "," + fa().toString();
}

function b134ShadowWithoutCapture(): string {
	let out = "";
	for (let i = 0; i < 2; i += 1) {
		let x = 100 + i;
		{
			let x = 900 + i;
			out = out + x.toString() + ",";
		}
		out = out + x.toString() + ",";
	}
	return out;
}

test "bug134: a nested-block shadow keeps its own storage inside a loop" {
	assert b134BlockShadowInLoop() === "900,901,901,902,902,903,|100,101,102,";
}

test "bug134: a nested-block shadow does not overwrite the captured slot" {
	assert b134BlockShadowNoLoop() === "900,901,cap=100";
}

test "bug134: a local in a nested arrow body is that arrow's own binding" {
	assert b134ShadowInNestedArrow() === "700,50";
}

test "bug134: an if-block shadow keeps its own storage" {
	assert b134ShadowInIfBlock() === "900,100";
}

test "bug134: shadowing without any capture is unchanged" {
	assert b134ShadowWithoutCapture() === "900,100,901,101,";
}
