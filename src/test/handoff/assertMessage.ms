import { refusedOnEveryBackend, compileToC, compileToJSWithStd } from "../helpers";

const NEEDLE = "an assert message must be a string";

function withMessage(decl: string, message: string): string {
	return `test "t" { ${decl} assert true, ${message}; }`;
}

test "an assert message that is not a string is refused on every backend" {
	const cases = [
		withMessage("const n: int32 = 2;", "n"),
		withMessage("const items: int32[] = [1, 2];", "items.length"),
		withMessage("const ok: boolean = true;", "ok"),
		withMessage("const o = { a: 1 };", "o"),
	];
	for (const source of cases) assert refusedOnEveryBackend(source, NEEDLE) == "", source;
}

test "an assert message that is a string or a template literal is accepted" {
	const cases = [
		withMessage("const s: string = \"x\";", "s"),
		withMessage("const n: int32 = 2;", "`n is ${n}`"),
		withMessage("const n: int32 = 2;", "n.toString()"),
	];
	for (const source of cases) {
		const c = compileToC(source);
		assert c.ok, c.error;
		const js = compileToJSWithStd(source);
		assert js.ok, js.error;
	}
}
