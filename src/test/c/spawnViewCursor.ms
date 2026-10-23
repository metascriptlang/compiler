// A task that writes data it owns takes no rc op on a view of a lent graph: the write is in another
// partition than the view's source (V5). Inference unit tests: `cursors.ms`.

import { compileToC } from "../helpers";

function thunkBodies(c: string): string {
	let out = "";
	let from = 0;
	for (const line of c.split("\n")) {
		if (line.contains("lifted_") && line.endsWith(") {") && !line.startsWith(" ") && !line.startsWith("\t")) {
			const open = c.indexOf(line, from);
			const close = c.indexOf("\n}", open);
			out = out + c.slice(open, close) + "\n";
			from = close;
		}
	}
	return out;
}

const PROGRAM = (holder: string, make: string) => `
class N { v: int32 = 1; next: N | null = null; }
${holder}
async function main(): Promise<int32> {
	const g = ${make};
	g.next = new N();
	const t = spawn(() => {
		let sum = 0;
		const own = ${make};
		for (let i = 0; i < 10; i += 1) {
			const view = g.next;
			own.next = new N();
			if (view != null) sum += view.v;
		}
		return sum;
	});
	return await t;
}
console.log(\`\${await main()}\`);
`;

test "E2E C: a task view of a lent graph takes no rc op beside a store to its own holder of the same type" {
	const r = compileToC(PROGRAM("", "new N()"));
	assert r.ok;
	const body = thunkBodies(r.ok ? r.value : "");
	assert body.length > 0;
	assert !body.contains("msIncrefCyclic(view");
	assert !body.contains("msDecrefCyclic(view");
}

test "E2E C: a task view of a lent graph takes no rc op beside a store to its own generic holder of the same type" {
	const r = compileToC(PROGRAM("class Cell<T> { v: int32 = 1; next: T | null = null; }", "new Cell<N>()"));
	assert r.ok;
	const body = thunkBodies(r.ok ? r.value : "");
	assert body.length > 0;
	assert !body.contains("msIncrefCyclic(view");
	assert !body.contains("msDecrefCyclic(view");
}
