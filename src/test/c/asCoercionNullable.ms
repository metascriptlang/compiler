// E2E C: as<Target> coercion — assignment context + nullable-ref formals.
// Split from protocols.ms (whose compileProjectToC call sites are pre-broken:
// un-annotated `const entries = [{...}]` arrays are rejected at the arg —
// pre-existing, reproduced under the pre-2026-07-27 compiler too).

import { compileToC } from "../helpers";

// =====================================================================
// asTarget through assignment + nullable-ref formals (neon Style→FlexStyle,
// 2026-07-27). `layoutStyle = style` where layoutStyle: Flex | null must
// synthesize style.asFlex(); without the extension the repr mismatch
// (union(number|string) field vs union(float32|string) field) must error,
// never raw-store.
// =====================================================================

const SF_PRELUDE = `
interface Sty { w: number | string | null; }
interface Flex { w: float32 | string | null; }
`;

const ASFLEX_EXT = `
export function asFlex(this s: Sty): Flex {
	const out: Flex = {};
	const v = s.w;
	if (v !== null) {
		if (typeof v === "string") { out.w = v as string; }
		else { out.w = (v as number) as float32; }
	}
	return out;
}
`;

test "E2E C: assignment to nullable-interface field synthesizes asFlex" {
	const src = SF_PRELUDE + ASFLEX_EXT + `
interface Panel { layout: Flex | null; }

function main(): void {
	const p: Panel = { layout: null };
	const s: Sty = { w: 80 };
	p.layout = s;
}
`;
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("asFlex");
}

test "E2E C: nullable-field repr mismatch without asFlex errors" {
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

test "E2E C: var-decl repr mismatch without asFlex errors" {
	const src = SF_PRELUDE + `
function main(): void {
	const s: Sty = { w: 80 };
	const f: Flex = s;
}
`;
	const c = compileToC(src);
	assert !c.ok;
}

test "E2E C: call-arg through nullable param synthesizes asFlex" {
	const src = SF_PRELUDE + ASFLEX_EXT + `
function takeFlex(f: Flex | null): void {}

function main(): void {
	const s: Sty = { w: 80 };
	takeFlex(s);
}
`;
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("asFlex");
}
