// A -O0 clang frame holds every local of a function at once, so the walkers recursing once per
// AST level overran an 8 MB stack near 110 levels; the dispatchers stay small.

import { builtModuleC } from "../helpers";
import { cwd } from "std/process";

const dispatcherLines = 300;

function bodyLines(c: string, name: string): number {
	const lines = c.split("\n");
	let found = 0;
	for (let i = 0; i < lines.length; i++) {
		if (!lines[i].startsWith("void " + name)) continue;
		if (!lines[i].endsWith("{")) continue;
		let j = i + 1;
		while (j < lines.length && lines[j] != "}") j++;
		found = j - i;
		break;
	}
	return found;
}

test "C: the AST visitor emits a dispatcher over per-group helpers" {
	const root = cwd();
	const src = `import { Node } from "${root}/src/ast/node";\nimport { forEachChild, mapChildren } from "${root}/src/ast/visitor";\n` +
		"export function probe(n: Node): void { forEachChild(n, (c: Node): void => {}); mapChildren(n, (c: Node): Node => c);}\n";
	const visitor = builtModuleC("walkerFrames", "probe", src, [], "visitor");
	for (const name of ["forEachChild", "mapChildren"]) {
		const n = bodyLines(visitor, name);
		assert n > 0 && n < dispatcherLines, `${name} dispatcher is ${n} lines`;
	}
}
