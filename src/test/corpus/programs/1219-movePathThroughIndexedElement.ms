// @stdout: moved 2 survivors 2
// @stdout: nested 2 survivors 2 1
// @stdout: string a|b
class Node { kids: int32[] = [1, 2]; name: string = "a"; }
class Tree { nodes: Node[] = [new Node(), new Node()]; }
class Forest { trees: Tree[] = [new Tree(), new Tree()]; }

let calls = 0;
function pick(): int32 { calls += 1; return 0; }

function direct(): string {
	const t = new Tree();
	const k = move t.nodes[pick()].kids;
	return `moved ${k.length} survivors ${t.nodes.length}`;
}

function nested(): string {
	const f = new Forest();
	const k = move f.trees[pick()].nodes[pick()].kids;
	return `nested ${k.length} survivors ${f.trees.length} ${f.trees[0].nodes.length - 1}`;
}

function text(): string {
	const t = new Tree();
	t.nodes[1].name = "b";
	const s = move t.nodes[pick()].name;
	return `string ${s}|${t.nodes[1].name}`;
}

console.log(direct());
console.log(nested());
console.log(text());
