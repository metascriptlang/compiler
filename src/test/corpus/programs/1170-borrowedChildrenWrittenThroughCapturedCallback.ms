// @stdout: captured-callback replaced=3 kept=true seen=a,b,c union-disjoint=a,b,c
class N {
	kids: N[] = [];
	label: string;
	constructor(label: string) { this.label = label; }
}

function visitAll(cb: (c: N) => void, nodes: N[]): void {
	for (let i = 0; i < nodes.length; i++) cb(nodes[i]);
}

function each(n: N, cb: (c: N) => void): void {
	visitAll(cb, n.kids);
}

function anyKid(n: N, test: (c: N) => boolean): boolean {
	let found = false;
	const scan = (c: N): void => { if (!found && test(c)) found = true; };
	each(n, scan);
	return found;
}

function tree(): N {
	const root = new N("root");
	root.kids.push(new N("a"));
	root.kids.push(new N("b"));
	root.kids.push(new N("c"));
	return root;
}

let out = "";

const replacing = tree();
let replaced = 0;
anyKid(replacing, (c: N): boolean => { replaced += 1; replacing.kids = []; return false; });
out += `captured-callback replaced=${replaced}`;

const reading = tree();
out += ` kept=${anyKid(reading, (c: N): boolean => c.label == "b")}`;

const seeing = tree();
const seen: string[] = [];
anyKid(seeing, (c: N): boolean => { seen.push(c.label); return false; });
out += ` seen=${seen.join(",")}`;

function walkDisjoint(root: N, other: (string | null)[]): string {
	const labels: string[] = [];
	each(root, (c: N): void => {
		other[0] = null;
		labels.push(c.label);
	});
	return labels.join(",");
}
out += ` union-disjoint=${walkDisjoint(tree(), ["x"])}`;
console.log(out);
