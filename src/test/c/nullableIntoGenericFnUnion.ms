import { compileToC } from "../helpers";

const PRELUDE = `
class Box { v: int32 = 1; }
interface Item { v: int32; }
function pick<T>(first: T | ((prev: T | null) => T)): boolean {
	return first === null;
}
class Holder {
	pick<T>(first: T | ((prev: T | null) => T)): boolean {
		return first === null;
	}
}
`;

function pickCall(body: string): string {
	const out = compileToC(PRELUDE + body);
	if (!out.ok) return "compile failed";
	for (const line of out.value.split("\n")) {
		if (line.contains("pick") && line.contains(" = ") && line.contains("(") && !line.contains("{")) return line;
	}
	return "no pick call";
}

test "E2E C: a null-holding class local reaches a generic T | fn parameter through the carrier" {
	const line = pickCall(`
const n: Box | null = null;
console.log(pick<Box | null>(n).toString());
`);
	assert line.contains("pick");
	assert !line.contains("(n__") && !line.contains(", n__");
}

test "E2E C: a null-holding interface local reaches a generic T | fn parameter through the carrier" {
	const line = pickCall(`
const n: Item | null = null;
console.log(pick<Item | null>(n).toString());
`);
	assert line.contains("pick");
	assert !line.contains("(n__") && !line.contains(", n__");
}

test "E2E C: a null-holding array local reaches a generic T | fn parameter through the carrier" {
	const line = pickCall(`
const n: int32[] | null = null;
console.log(pick<int32[] | null>(n).toString());
`);
	assert line.contains("pick");
	assert !line.contains("(n__") && !line.contains(", n__");
}

test "E2E C: a null-holding local reaches a generic method T | fn parameter through the carrier" {
	const line = pickCall(`
const h = new Holder();
const n: Box | null = null;
console.log(h.pick<Box | null>(n).toString());
`);
	assert line.contains("pick");
	assert !line.contains("(n__") && !line.contains(", n__");
}
