// nim-guard: a fresh value in a switch discriminant is destroyed
//
// INVARIANT (injectdestructors.nim:678 nkCaseStmt: `p(n[0], c, s, normal)`;
//   NIM-REF AN-13 universal walk): the analyzer walks the selector like any other
//   position, so a fresh managed value in it is destroyed each time it is evaluated.
//
// WHAT IT CATCHES: processSwitch walking only the case bodies, so `switch (mk(i).v)`
//   on an ordinal (a real C switch) leaks one TsBox per evaluation. Axes: the fresh
//   value read directly, and nested one level deeper as a call argument.
//
// RED MEANS: processSwitch stopped walking switchDisc. Run /trace-nim on
//   processSwitch in inject.ms.
// GUARD-BALANCE TsBox
// GUARD-JS

class TsBox { v: int32; constructor(v: int32) { this.v = v; } }

function mk(v: int32): TsBox { return new TsBox(v); }
function twice(b: TsBox): int32 { return b.v * 2; }

function run(): int32 {
	let r = 0;
	for (let i: int32 = 0; i < 3; i += 1) {
		switch (mk(i).v) {
			case 1: r += 10; break;
			default: r += 1;
		}
		switch (twice(mk(i))) {
			case 2: r += 100; break;
			default: r += 1000;
		}
	}
	return r;
}

if (run() == 2112) {
	console.log("GUARD-OK");
} else {
	process.exit(1);
}
