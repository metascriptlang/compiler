// @acyclic prunes the cycle classification: a class that can reach itself registers for cycle
// collection unless it is marked, an extended class is pruned too, and the decorator applies to a
// class only. Runtime behaviour: corpus `acyclicClassFreedWithoutCollector`.

import { compileToC } from "../helpers";

function typeInfoOf(c: string, name: string): string {
	for (const line of c.split("\n")) {
		if (line.contains(`msTypeInfo ${name}`) && line.contains(`.name = "${name}"`)) return line;
	}
	return "";
}

const NODE = `class Node {
	next: Node | null = null;
}
const a = new Node();
a.next = new Node();
console.log("ok");
`;

test "E2E C: a self-referencing class registers for cycle collection" {
	const r = compileToC(NODE);
	assert r.ok, r.ok ? "" : r.error;
	assert typeInfoOf(r.ok ? r.value : "", "Node").contains(".isCyclic = MS_TRUE");
}

test "E2E C: an @acyclic class does not" {
	const r = compileToC("@acyclic\n" + NODE);
	assert r.ok, r.ok ? "" : r.error;
	assert typeInfoOf(r.ok ? r.value : "", "Node").contains(".isCyclic = MS_FALSE");
}

test "E2E C: an extended @acyclic class is pruned too" {
	const r = compileToC(`@acyclic
class Base {
	next: Base | null = null;
}
class Leaf extends Base { tag: int32 = 0; }
const a = new Leaf();
a.next = new Base();
console.log("ok");
`);
	assert r.ok, r.ok ? "" : r.error;
	assert typeInfoOf(r.ok ? r.value : "", "Base").contains(".isCyclic = MS_FALSE");
}

test "E2E C: @acyclic on a function is refused" {
	const r = compileToC("@acyclic\nfunction f(): int32 { return 1; }\nconsole.log(f());\n");
	assert !r.ok;
	assert (r.ok ? "" : r.error).contains("@acyclic applies to a class, not to 'f'");
}
