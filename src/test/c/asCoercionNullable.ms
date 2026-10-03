// E2E C: runtime converter — assignment context + nullable-ref formals.
// Split from protocols.ms (whose compileProjectToC call sites are pre-broken:
// un-annotated `const entries = [{...}]` arrays are rejected at the arg —
// pre-existing, reproduced under the pre-2026-07-27 compiler too).

import { compileToC } from "../helpers";

// =====================================================================
// A converter through assignment + nullable-ref formals (neon Style→FlexStyle,
// 2026-07-27). `layoutStyle = style` where layoutStyle: Flex | null must
// call styToFlex(style); without the converter the repr mismatch
// (union(number|string) field vs union(float32|string) field) must error,
// never raw-store.
// =====================================================================

const SF_PRELUDE = `
interface Sty { w: number | string | null; }
interface Flex { w: float32 | string | null; }
`;

const STY_TO_FLEX = `
export converter styToFlex(s: Sty): Flex {
	const out: Flex = {};
	const v = s.w;
	if (v !== null) {
		if (typeof v === "string") { out.w = v as string; }
		else { out.w = (v as number) as float32; }
	}
	return out;
}
`;

test "E2E C: assignment to nullable-interface field calls the converter" {
	const src = SF_PRELUDE + STY_TO_FLEX + `
interface Panel { layout: Flex | null; }

function main(): void {
	const p: Panel = { layout: null };
	const s: Sty = { w: 80 };
	p.layout = s;
}
`;
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("styToFlex");
}

test "E2E C: nullable-field repr mismatch without a converter errors" {
	const src = SF_PRELUDE + `
interface Panel { layout: Flex | null; }

function main(): void {
	const p: Panel = { layout: null };
	const s: Sty = { w: 80 };
	p.layout = s;
}
`;
	const c = compileToC(src);
	assert !c.ok;
}

test "E2E C: var-decl repr mismatch without a converter errors" {
	const src = SF_PRELUDE + `
function main(): void {
	const s: Sty = { w: 80 };
	const f: Flex = s;
}
`;
	const c = compileToC(src);
	assert !c.ok;
}

test "E2E C: call-arg through nullable param calls the converter" {
	const src = SF_PRELUDE + STY_TO_FLEX + `
function takeFlex(f: Flex | null): void {}

function main(): void {
	const s: Sty = { w: 80 };
	takeFlex(s);
}
`;
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("styToFlex");
}

test "E2E C: narrowing a nullable union by member builds the carrier, never a reinterpret" {
	const src = `
function main(): void {
	const a: number | string | null = "row";
	const n: string | null = a as string | null;
	console.log(n === null ? "N" : "V");
}
`;
	const c = compileToC(src);
	assert c.ok;
	assert !c.value.contains("*(Maybe_p1*)&");
	assert c.value.contains("msRaiseFieldError");
}

test "E2E C: dropping only null needs no variant check" {
	const src = `
function main(): void {
	const b: string | null = "row";
	console.log(b as string);
}
`;
	const c = compileToC(src);
	assert c.ok;
	assert !c.value.contains("msRaiseFieldError");
}

const ALIGN_PRELUDE = "type Align = \"auto\" | \"center\" | \"stretch\";\ntype Wire = number | string | null;\n"
	+ "function show(a: Align | null): string { if (a == null) return \"null\"; const t: string = a; return t; }\n";

test "E2E C: an as into a nullable string-literal union tests membership without reinterpreting the carrier" {
	const cases = [
		{ name: "a string", source: "function f(s: string): Align | null { return s as Align | null; }\nconsole.log(show(f(\"center\")));" },
		{ name: "a nullable string", source: "function f(s: string | null): Align | null { return s as Align | null; }\nconsole.log(show(f(\"center\")));" },
	];
	for (const item of cases) {
		const c = compileToC(ALIGN_PRELUDE + item.source);
		assert c.ok, item.name;
		assert c.value.contains("msStrLitConv("), item.name;
		assert !c.value.contains("*(Maybe_"), item.name;
	}
}

test "E2E C: an as from a nullable union into a string-literal union tests membership" {
	const c = compileToC(ALIGN_PRELUDE + "function f(v: Wire): Align { return v as Align; }\nconst w: Wire = \"center\";\nconsole.log(show(f(w)));");
	assert c.ok;
	assert c.value.contains("msStrLitConv(");
}
