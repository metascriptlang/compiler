// @stdout: clear=28:cfg:
// @stdout: after push 1
// @stdout: keepOne=29:cfg:
// @stdout: node=7 left 0
class Node {
	value: int32;
	constructor(value: int32) { this.value = value; }
}

function clear(a: string[], s: string): void {
	a.length = 0;
	console.log(`clear=${s.length}:${s.slice(0, 4)}`);
	a.push("z");
	console.log(`after push ${a.length}`);
}

function keepOne(a: string[], s: string): void {
	a.length = 1;
	console.log(`keepOne=${s.length}:${s.slice(0, 4)}`);
}

function dropNodes(a: Node[], n: Node): void {
	a.length = 0;
	console.log(`node=${n.value} left ${a.length}`);
}

function run(): void {
	const texts: string[] = [`cfg:${"x".repeat(24)}`, `cfg:${"y".repeat(25)}`];
	clear(texts, texts[0]);
	const more: string[] = [`cfg:${"x".repeat(24)}`, `cfg:${"y".repeat(25)}`];
	keepOne(more, more[1]);
	const nodes: Node[] = [new Node(7)];
	dropNodes(nodes, nodes[0]);
}
run();
