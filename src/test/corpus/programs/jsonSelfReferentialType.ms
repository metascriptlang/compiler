// @stdout: json-self-ref ok b c y 3 x
struct Node {
	key: string;
	children: Node[];
}

struct Tree {
	nodes: Node[];
}

interface Entry {
	name: string;
	nested: Entry[];
}

struct Group {
	label: string;
	members: Member[];
}

struct Member {
	id: int32;
	groups: Group[];
}

function count(n: Node): int32 {
	let total = 1;
	for (const c of n.children) total = total + count(c);
	return total;
}

const tree: Tree = { nodes: [{ key: "a", children: [{ key: "b", children: [{ key: "c", children: [] }] }] }] };
const treeText = JSON.stringify(tree);
const tree2 = JSON.parse<Tree>(treeText);
const first = tree2.ok ? tree2.value.nodes[0].children[0].key : "refused";
const size = tree2.ok ? count(tree2.value.nodes[0]) : 0;
const deep = tree2.ok ? tree2.value.nodes[0].children[0].children[0].key : "refused";

const entry: Entry = { name: "x", nested: [{ name: "y", nested: [] }] };
const entryText = JSON.stringify(entry);
const entry2 = JSON.parse<Entry>(entryText);
const inner = entry2.ok ? entry2.value.nested[0].name : "refused";

const group: Group = { label: "x", members: [{ id: 3, groups: [{ label: "z", members: [] }] }] };
const group2 = JSON.parse<Group>(JSON.stringify(group));
const id = group2.ok ? group2.value.members[0].id : -1;
const label = group2.ok ? group2.value.label : "refused";

const bad = JSON.parse<Tree>("{\"nodes\":[{\"key\":\"a\",\"children\":[{\"key\":1,\"children\":[]}]}]}");

const same = treeText == "{\"nodes\":[{\"key\":\"a\",\"children\":[{\"key\":\"b\",\"children\":[{\"key\":\"c\",\"children\":[]}]}]}]}"
	&& entryText == "{\"name\":\"x\",\"nested\":[{\"name\":\"y\",\"nested\":[]}]}"
	&& size == 3 && !bad.ok;
console.log((same ? "json-self-ref ok " : "json-self-ref bad ") + first + " " + deep + " " + inner + " " + id.toString() + " " + label);
