import { compileToCWithStd, compileProjectToJSWithStd } from "../helpers";

test "value storage writes require a mutable root through every access path" {
	const writes = ["s.a = 2;", "s.inner.v = 3;", "s.xs[0] = 4;", "k = 2;", "limit = 2;", "take(s);", "s.a += 1;", "k++;"];
	for (const binding of ["const", "let"]) {
		for (const body of writes) {
			const result = compileToCWithStd(`
struct Inner { v: int32; }
struct State { a: int32; inner: Inner; xs: int32[3]; }
function take(ref s: State): void { s.a = 1; }
${binding} limit: int32 = 1;
function run(): void {
	${binding} s: State = { a: 1, inner: { v: 1 }, xs: [1, 2, 3] };
	${binding} k: int32 = 1;
	${body}
	console.log(s.a, k, limit);
}
run();
`);
			assert result.ok == (binding == "let"), binding + ": " + body;
		}
	}
}

test "string byte views permit reads and detached writes but never mutable aliases" {
	const refused = [
		"const b = s.asBytes(); b[0] = 65;",
		"const b = s.asBytes(); b.push(66);",
		"const b: uint8[] = s.asBytes();",
	];
	for (const body of refused) {
		const source = `const s = "x".repeat(4); ${body}`;
		const c = compileToCWithStd(source);
		const js = compileProjectToJSWithStd([{ entryPath: "test/view.ms", entrySource: source }], "test/view.ms");
		assert !c.ok, body;
		assert js.startsWith("ERROR:"), body;
	}
	const source = `const s = "x".repeat(4); const view = s.asBytes(); const copy = view.slice(0, view.length); copy[0] = 65; copy.push(66); console.log(view[0], copy.asString());`;
	const c = compileToCWithStd(source);
	const js = compileProjectToJSWithStd([{ entryPath: "test/view.ms", entrySource: source }], "test/view.ms");
	assert c.ok, c.ok ? "" : c.error;
	assert !js.startsWith("ERROR:"), js;
}

test "an unprojected discriminant is not writable even through a parameter" {
	const source = `struct Point { kind: "point"; x: int32; } interface Named { kind: "named"; name: string; } export function write(value: Point | Named): void { value.kind = "point"; }`;
	const c = compileToCWithStd(source);
	assert !c.ok;
}
