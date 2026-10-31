import { checkOnly } from "../helpers";

function errorsAt(source: string, text: string): string {
	const at: string[] = [];
	for (const e of checkOnly(source).ctx.errors) {
		if (e.message.contains(text)) at.push(`${e.line}:${e.column}`);
	}
	return at.join(",");
}

test "an unknown parameter type of an arrow or function expression is reported at the type" {
	const source = `
const f = (e: Missing) => 1;
const h = function (e: Missing) { return 1; };
function run(cb: (n: number) => number): number { return cb(1); }
const r = run((e: Missing) => 1);
`;
	assert errorsAt(source, "Unresolved type 'Missing'") == "2:15,3:24,5:19";
}

test "an annotated arrow bound to a variable reports an unknown type once, at the type" {
	const source = `
const f = (e: Missing): number => 1;
const g = (n: number): Nope => n;
`;
	assert errorsAt(source, "Unresolved type 'Missing'") == "2:15";
	assert errorsAt(source, "Unresolved type 'Nope'") == "3:24";
}

test "a return annotation an arrow cannot return is refused wherever the arrow is written" {
	const source = `
function run(cb: (xs: number[]) => number): number { return cb([1]); }
const bound = (xs: number[]): Span<number> => xs;
const r = run((xs: number[]): Span<number> => xs);
`;
	assert errorsAt(source, "cannot return Span<number>") == "3:31,4:31";
}
