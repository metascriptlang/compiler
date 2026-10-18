import { checkOnly } from "../helpers";

const LIB = `
class Box { n: int32 = 1; }
function str(): string { return "s"; }
function num(): number { return 1; }
function box(): Box { return new Box(); }
function res(): Result<string, string> { return Result.ok("a"); }
`;

function refusals(use: string): string[] {
	return checkOnly(LIB + use).errors.filter(e => e.contains("needs a Result operand"));
}

test "try catch on a string operand is refused at the operand" {
	const e = refusals(`const v = try str() catch "caught";`);
	assert e.length == 1, e.join("\n");
	assert e[0].contains("'string', not a Result"), e[0];
}

test "try catch on a number operand is refused at the operand" {
	const e = refusals(`const v = try num() catch 0;`);
	assert e.length == 1, e.join("\n");
	assert e[0].contains("'number', not a Result"), e[0];
}

test "try catch on a class operand is refused at the operand" {
	const e = refusals(`const v = try box() catch new Box();`);
	assert e.length == 1, e.join("\n");
	assert e[0].contains("'Box', not a Result"), e[0];
}

test "try without catch on a non-Result operand is refused" {
	const e = refusals(`function f(): Result<string, string> { const x = try num(); return Result.ok("a"); }`);
	assert e.length == 1, e.join("\n");
}

test "try catch on a Result operand stays accepted" {
	assert refusals(`const v = try res() catch "d";`).length == 0;
	assert checkOnly(LIB + `const v = try res() catch "d";`).errors.length == 0;
}
