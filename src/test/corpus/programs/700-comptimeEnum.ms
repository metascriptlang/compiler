// @maxrss: 30
// @stdout: comptime-enum PASS
// @skip-js: js emits Color_Red references but drops the enum decl when C folded its uses; js audit 2026-09-01
// note: Enum-member ordinals inside comptime/macro eval. The ordinal was split across two channels — KEY on the member's resolvedSym, VALUE only in the Raiser VM's enumMap (populated solely from physically-injected EnumDecls). A single-file/local enum had an empty enumMap → members folded to nil → wrong comptime value (single-file @comptime yielded the wrong ordinal; at HEAD this program fails 'null not assignable to number'). Fix: rgen reads the ordinal self-contained from the member's EnumLiteral type (expressions.ms), so a local enum resolves the same as a cross-module one. Asserts explicit ordinals (Green=5 via @comptime helper, Blue=9 via macro helper, Red=3 runtime) so a nil-fold surfaces as a wrong number, not a lucky match-fallthrough. Remaining known gap (separate pre-existing root, not covered): a direct enum-member read in a body with NO helper call to seed the enum type (e.g. `@comptime { return E.M as number }` with a local E) — the type collector seeds only from injected fn signatures, so E is never injected and the inner check can't resolve it; crashes at HEAD too.

// Native guard for enum-member ordinals inside comptime/macro evaluation.
// Root cause (fixed): the ordinal was split across two channels — the KEY rode
// on the member's resolvedSym, but the VALUE lived only in the Raiser VM's
// enumMap, populated ONLY from EnumDecl nodes physically injected into the
// synthetic program. A single-file/local enum therefore had an empty enumMap
// and folded members to nil (wrong value). Fix: the ordinal is read
// self-contained from the member's EnumLiteral type at rgen (expressions.ms),
// independent of enumMap — so a local enum resolves the same as a cross-module
// one. Assertions use EXPLICIT ordinals so a nil-fold surfaces as a wrong
// number, not a lucky match-fallthrough. Building + PASS is the test.

import { Node, NodeKind } from "std/meta";

enum Color { Red = 3, Green = 5, Blue = 9 }

function pickGreen(): Color { return Color.Green; }
function ordOf(c: Color): number { return c as number; }
function blueOrd(): number { return Color.Blue as number; }

// @comptime reading a local enum via a helper — was the broken single-file case.
const CT: number = @comptime { const c = pickGreen(); return ordOf(c); };  // → 5

// Macro reading a local enum via a helper.
macro mBlue(a: Node): Node {
	return { kind: NodeKind.NumberLiteral, line: a.line, column: a.column, value: blueOrd(), isFloat: false };
}

function main(): void {
	const m: number = mBlue(0);          // macro → 9
	const rt: number = ordOf(Color.Red); // runtime → 3
	if (CT === 5 && m === 9 && rt === 3) {
		console.log("comptime-enum PASS");
	} else {
		console.log("comptime-enum FAIL CT=" + CT.toString() + " m=" + m.toString() + " rt=" + rt.toString());
	}
}
main();
