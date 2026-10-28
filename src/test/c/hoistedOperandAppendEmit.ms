// E2E: a self-append whose operand is hoisted (`try`, `match`, `await`) keeps
// appending in place on a local only its own routine names, and still reads the
// target first when a closure can change it before the operand runs.

import { compileToC } from "../helpers";

function emitFor(body: string): string {
	const c = compileToC(`
		function cell(i: int32): Result<string, string> { return Result.ok(String(i)); }
		async function part(i: int32): Promise<string> { return String(i); }
		${body}
	`);
	return c.ok ? c.value : "";
}

const local: string[][] = [
	["try", `function f(): Result<string, string> { let out = ""; for (let i: int32 = 0; i < 4; i++) { out += try cell(i); } return Result.ok(out); }
		console.log(f().ok);`],
	["plus", `function f(): Result<string, string> { let out = ""; for (let i: int32 = 0; i < 4; i++) { out = out + try cell(i); } return Result.ok(out); }
		console.log(f().ok);`],
	["match", `function f(): string { let out = ""; for (let i: int32 = 0; i < 4; i++) { out += match (i % 2) { 0 => String(i), _ => "x" }; } return out; }
		console.log(f());`],
	["await", `async function f(): Promise<string> { let out = ""; for (let i: int32 = 0; i < 4; i++) { out += await part(i); } return out; }
		f().then((s: string) => console.log(s));`],
];

test "E2E C: a hoisted operand appends in place on a local only its routine names" {
	for (const pair of local) {
		const name = pair[0];
		const c = emitFor(pair[1]);
		assert c != "", name;
		assert c.contains("msStringAppend("), name;
		assert !c.contains("msStringConcat("), name;
	}
}

test "E2E C: a hoisted operand reads a closure-written target first" {
	const c = emitFor(`function f(): Result<string, string> {
			let out = "a";
			const bump = (): Result<string, string> => { out = "b"; return Result.ok("c"); };
			out += try bump();
			return Result.ok(out);
		}
		console.log(f().ok);`);
	assert c != "";
	assert c.contains("msStringConcat(");
}
