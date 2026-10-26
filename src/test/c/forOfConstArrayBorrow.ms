import { compileToC } from "../helpers";

const TREE = `
class Node { kids: Node[] = []; tag: int32 = 0; }
function make(n: Node): Node[] { return n.kids.slice(0); }
export function constField(n: Node): int32 { const kids = n.kids; let s: int32 = 0; for (const k of kids) s = s + k.tag; return s; }
export function constCall(n: Node): int32 { const kids = make(n); let s: int32 = 0; for (const k of kids) s = s + k.tag; return s; }
const a = new Node(); a.kids.push(new Node());
console.log(constField(a) + constCall(a));
`;

function functionBody(code: string, name: string): string {
	for (const line of code.split("\n")) {
		const at = line.indexOf(" " + name);
		if (at < 0 || !line.endsWith(" {") || line.indexOf("(", at) < 0) continue;
		const start = code.indexOf(line + "\n");
		const end = code.indexOf("\n}", start);
		if (end >= 0) return code.slice(start, end);
	}
	return "";
}

function bodyOf(name: string): string {
	const result = compileToC(TREE);
	if (!result.ok) return result.error;
	return functionBody(result.value, name);
}

test "a for-of over a field array held by a const borrows the array and each element" {
	const body = bodyOf("constField");
	assert body != "", "constField has no definition";
	assert !body.contains("msIncref") && !body.contains("msDecref"), body;
	assert !body.contains("dollariter"), body;
}

test "a for-of over an owned array held by a const borrows each element" {
	const body = bodyOf("constCall");
	assert body != "", "constCall has no definition";
	assert !body.contains("msIncref"), body;
	assert !body.contains("dollariter"), body;
}
