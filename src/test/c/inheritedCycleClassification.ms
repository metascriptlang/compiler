// A class's parent lends it fields, not a reference: a local of a class that extends an extended
// parent and whose fields cannot reach back is released without the collector, while a local
// typed by the parent, which can hold any subclass, keeps the cyclic release once one subclass
// can reach back. A field typed by an open class still makes its holder cyclic.

import { compileToC } from "../helpers";

function releaseOf(src: string, fn: string): string {
	const r = compileToC(src);
	if (!r.ok) return "compile error: " + r.error;
	const lines = r.value.split("\n");
	let inside = false;
	for (const line of lines) {
		if (!line.startsWith(" ") && line.contains(`${fn}__`) && line.endsWith(") {")) inside = true;
		else if (inside && line == "}") return "no release in " + fn;
		else if (inside && line.contains("msDecrefCyclic(")) return "cyclic";
		else if (inside && line.contains("msDecref(")) return "plain";
	}
	return "no function " + fn;
}

const VIEWS = `class Store { bytes: int32[] = []; }
class View { store: Store | null = null; length: int32 = 0; }
class Bytes extends View { tag: int32 = 0; }
class Words extends View { width: int32 = 2; }
function useBytes(): int32 { const b = new Bytes(); return b.length + b.tag; }
function useView(): int32 { const v: View = new Words(); return v.length; }
`;

test "E2E C: a local of a subclass of an extended class that cannot reach back is released without the collector" {
	assert releaseOf(VIEWS + "console.log(useBytes());\n", "useBytes") == "plain";
}

test "E2E C: a local typed by the extended parent keeps the cyclic release when a subclass can reach back" {
	const src = VIEWS + `class Linked extends View { prev: View | null = null; }
console.log(useView());
`;
	assert releaseOf(src, "useView") == "cyclic";
}

test "E2E C: a subclass holding a field typed by its open parent keeps the cyclic release" {
	const src = VIEWS + `class Linked extends View { prev: View | null = null; }
function useLinked(): int32 { const l = new Linked(); l.prev = new Bytes(); return l.length; }
console.log(useLinked() + useBytes() + useView());
`;
	assert releaseOf(src, "useLinked") == "cyclic";
}
