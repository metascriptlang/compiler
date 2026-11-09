import { compileToC } from "../helpers";

function bodyOf(code: string, fn: string): string {
	for (const line of code.split("\n")) {
		if (line.endsWith(" {") && line.indexOf(" " + fn + "__") >= 0) {
			const start = code.indexOf(line + "\n");
			return code.slice(start, code.indexOf("\n}", start));
		}
	}
	return "";
}

function count(text: string, token: string): int32 {
	return (text.split(token).length - 1) as int32;
}

const OBJECT_FOR_OF = `
type Circle = { kind: "circle"; r: float64 };
type Rect = { kind: "rect"; w: float64; h: float64 };
type Shape = Circle | Rect;
type Tagged = { kind: int32; r: float64; w: float64; h: float64 };
function area(s: Shape): float64 {
	switch (s.kind) {
		case "circle": return s.r * s.r * 3.0;
		case "rect": return s.w * s.h;
	}
}
function tArea(s: Tagged): float64 {
	switch (s.kind) {
		case 0: return s.r * s.r * 3.0;
		default: return s.w * s.h;
	}
}
const shapes: Shape[] = [];
const tagged: Tagged[] = [];
function overwrite(s: Tagged): float64 {
	tagged[0] = { kind: 9, r: 0, w: 0, h: 0 };
	return s.r;
}
function sumShapes(xs: Shape[]): float64 {
	let a: float64 = 0;
	for (const s of xs) a = a + area(s);
	return a;
}
function sumTagged(xs: Tagged[]): float64 {
	let a: float64 = 0;
	for (const s of xs) a = a + tArea(s);
	return a;
}
function sumOverwrite(xs: Tagged[]): float64 {
	let a: float64 = 0;
	for (const s of xs) a = a + overwrite(s);
	return a;
}
for (let i = 0; i < 10; i = i + 1) {
	if (i % 3 == 0) shapes.push({ kind: "circle", r: i }); else shapes.push({ kind: "rect", w: i, h: 2 });
	tagged.push({ kind: i % 2, r: i, w: i, h: 2 });
}
console.log(\`\${sumShapes(shapes)} \${sumTagged(tagged)} \${sumOverwrite(tagged)}\`);
`;

test "a for-of element handed to a routine that overwrites the array stays held" {
	const result = compileToC(OBJECT_FOR_OF);
	assert result.ok, result.error;
	const body = bodyOf(result.value, "sumOverwrite");
	assert body != "" && count(body, "Copy(") + count(body, "msIncref(") >= 1, body;
}
