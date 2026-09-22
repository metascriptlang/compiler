// Symptom: a folded false branch without an else crashed the C build.
// Root cause: DCE returned the synthetic IfStmt's null alternate as a statement.
// Fix: replace an absent dead alternate with an empty block.
import { compileToCWithStd } from "../helpers";

function compileDeadBranch(body: string): string {
	const result = compileToCWithStd(`
class Pt { x: int32; y: int32; constructor(x: int32, y: int32) { this.x = x; this.y = y; } }
function tally(p: Pt): boolean { return p.x > 0; }
function main(): int32 { ${body} console.log(2); return 0; }
process.exit(main());
`);
	return result.ok ? "" : result.error;
}

test "bug200: folded false and-new branch without else compiles" {
	const error = compileDeadBranch("if (false && tally(new Pt(1, 2))) { console.log(1); }");
	assert error == "", error;
}

test "bug200: direct false branch without else compiles" {
	const error = compileDeadBranch("if (false) { tally(new Pt(1, 2)); }");
	assert error == "", error;
}

test "bug200: nested folded false branch without else compiles" {
	const error = compileDeadBranch("for (let i = 0; i < 1; i += 1) { if (false && tally(new Pt(1, 2))) { console.log(1); } }");
	assert error == "", error;
}
