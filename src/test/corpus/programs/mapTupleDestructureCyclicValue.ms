// @stdout: 2 2 2
// note: a tuple destroy hook over a cyclic class member has no owner object to drop an edge from

class Query { group: Group | null = null; }
class Group {
	queries: Query[];
	constructor(queries: Query[]) { this.queries = queries; }
}

function viaMap(): int32 {
	const m = new Map<string, Group>();
	const q = new Query();
	const g = new Group([q]);
	q.group = g;
	m.set("a", g);
	let total = 0;
	for (const [key, group] of m) { total += key.length + group.queries.length; }
	return total;
}

function viaCyclicKey(): int32 {
	const m = new Map<Group, string>();
	const q = new Query();
	const g = new Group([q]);
	q.group = g;
	m.set(g, "a");
	let total = 0;
	for (const [group, key] of m) { total += key.length + group.queries.length; }
	return total;
}

function viaArray(): int32 {
	const q = new Query();
	const g = new Group([q]);
	q.group = g;
	const pairs: Vec<[string, Group]> = [["a", g]];
	let total = 0;
	for (const [key, group] of pairs) { total += key.length + group.queries.length; }
	return total;
}

console.log(`${viaMap()} ${viaCyclicKey()} ${viaArray()}`);
