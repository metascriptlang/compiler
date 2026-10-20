import { checkOnly } from "../helpers";

const SRC_INT = `
function f(c: boolean): int32 { if (c) return; return 3; }
`;

const SRC_CLASS = `
class Box { v: int32 = 0; }
function g(c: boolean): Box { if (c) { return; } return new Box(); }
`;

const SRC_ASYNC = `
async function h(c: boolean): Promise<string> { if (c) return; return "a"; }
`;

const SRC_VALID = `
class Box { v: int32 = 0; constructor() { if (this.v > 0) return; } }
function n(c: boolean): int32 | null { if (c) return; return 3; }
async function p(c: boolean): Promise<Box | null> { if (c) return; return new Box(); }
function v(c: boolean): void { if (c) return; }
async function w(c: boolean): Promise<void> { if (c) return; }
function* gen(): Iterator<int32> { yield 1; return; }
const inferred = (c: boolean) => { if (c) return; return 3; };
`;

function errorsOf(source: string): string {
	return checkOnly(source).errors.join("\n");
}

test "a bare return in a function whose written return type needs a value is refused" {
	const intText = errorsOf(SRC_INT);
	assert intText.contains("'f' returns 'int32', and a bare 'return;' gives no value: return a value, or write the return type as 'int32 | null'"), "int32: " + intText;
	const classText = errorsOf(SRC_CLASS);
	assert classText.contains("'g' returns 'Box', and a bare 'return;' gives no value"), "class: " + classText;
	const asyncText = errorsOf(SRC_ASYNC);
	assert asyncText.contains("'h' returns 'string', and a bare 'return;' gives no value"), "async: " + asyncText;
}

test "a bare return stays legal where the return type holds null or no value" {
	const result = checkOnly(SRC_VALID);
	assert result.errors.length == 0, "nullable, void, generator, constructor and inferred bare returns must check: " + result.errors.join("\n");
}
