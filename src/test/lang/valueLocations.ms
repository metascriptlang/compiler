struct StoredValue { n: int32; }
struct StoredInner { v: int32; tags: Vec<int32>; }
struct StoredOuter { a: int32; inner: StoredInner; }
struct StoredField { value: StoredValue; }
struct LocatedPet { hunger: int32; name: string; inner: StoredInner; tags: Vec<int32>; }
struct LocatedBag { tags: Vec<int32>; n: int32; }

function keepValue(values: StoredValue[], value: StoredValue): void { values.push(value); }
function rebindValue(value: StoredValue): int32 { value = { n: 9 }; return value.n; }
function rebindSequence(values: Vec<int32>): int32 { values = [4, 4]; return values[0]; }
function feed(this ref pet: LocatedPet, amount: int32): void { pet.hunger += amount; }
function readHunger(this pet: LocatedPet): int32 { return pet.hunger; }
function locatedPet(value: int32): LocatedPet {
	return { hunger: value, name: "a", inner: { v: 1, tags: [2] }, tags: [1, 2] };
}
let locationReads: int32 = 0;
function selectedIndex(): int32 { locationReads++; return 1; }

test "valueLocations: native stores copy value elements rather than sharing their source" {
	let value: StoredValue = { n: 1 };
	const owned: Vec<StoredValue> = [];
	const shared: StoredValue[] = [];
	const throughCall: StoredValue[] = [];
	owned.push(value);
	shared.push(value);
	keepValue(throughCall, value);
	value.n = 2;
	assert owned[0].n == 1 && shared[0].n == 1 && throughCall[0].n == 1;
	const filled: StoredValue[] = [{ n: 0 }, { n: 0 }];
	filled.fill(value);
	filled[0].n = 5;
	assert filled[1].n == 2 && value.n == 2;
}

test "valueLocations: native element consumers hand out independent value copies" {
	const source: StoredValue[] = [{ n: 1 }];
	const slice = source.slice(0, 1);
	let element = source.at(0)!;
	const concatenated = source.concat([]);
	const spread: StoredValue[] = [...source];
	slice[0].n = 5;
	element.n = 6;
	concatenated[0].n = 7;
	spread[0].n = 8;
	assert source[0].n == 1;
	assert slice[0].n == 5 && element.n == 6;
	assert concatenated[0].n == 7 && spread[0].n == 8;
}

test "valueLocations: map stores copy nested structs and their owned sequences" {
	let source: StoredOuter = { a: 1, inner: { v: 2, tags: [1] } };
	const values = new Map<string, StoredOuter>();
	values.set("key", source);
	source.inner.tags.push(5);
	source.inner.v = 7;
	const stored = values.get("key")!;
	assert stored.a == 1 && stored.inner.v == 2;
	assert stored.inner.tags.length == 1 && stored.inner.tags[0] == 1;
}

test "valueLocations: assignment updates existing local field and element locations" {
	let local: StoredValue = { n: 1 };
	const localView = local as Ptr<StoredValue>;
	local = { n: 2 };
	let holder: StoredField = { value: { n: 1 } };
	const fieldView = holder.value as Ptr<StoredValue>;
	holder.value = { n: 3 };
	let elements: StoredValue[2] = [{ n: 1 }, { n: 1 }];
	const elementView = elements[1] as Ptr<StoredValue>;
	locationReads = 0;
	elements[selectedIndex()] = { n: 4 };
	assert locationReads == 1;
	assert localView.n == 2 && fieldView.n == 3 && elementView.n == 4;
	assert elements[0].n == 1;
	elements[1] = { n: 6 };
	assert elementView.n == 6;
}

test "valueLocations: in-place aggregate assignment preserves nested locations without aliasing its source" {
	let elements: StoredOuter[1] = [{ a: 1, inner: { v: 2, tags: [1] } }];
	const view = elements[0] as Ptr<StoredOuter>;
	const nested = elements[0].inner as Ptr<StoredInner>;
	const source: StoredOuter = { a: 3, inner: { v: 4, tags: [9, 9] } };
	elements[0] = source;
	assert view.a == 3 && nested.v == 4;
	assert view.inner.tags.length == 2 && view.inner.tags[1] == 9;
	source.inner.tags.push(1);
	assert view.inner.tags.length == 2;
}

test "valueLocations: value parameters and iteration views rebind without replacing the caller" {
	let value: StoredValue = { n: 1 };
	assert rebindValue(value) == 9 && value.n == 1;
	const owned: Vec<int32> = [1, 2];
	assert rebindSequence(owned) == 4 && owned[0] == 1;
	const shared: StoredValue[] = [{ n: 1 }];
	for (let item of shared) { item = { n: 9 }; }
	assert shared[0].n == 1;
}

test "valueLocations: explicit pointer dereference distinguishes mutation copying and replacement" {
	let elements: LocatedPet[1] = [locatedPet(1)];
	const view = elements[0] as Ptr<LocatedPet>;
	view[].hunger = 4;
	assert elements[0].hunger == 4;
	view[].feed(3);
	assert elements[0].hunger == 7 && view[].readHunger() == 7;
	let snapshot = view[];
	snapshot.hunger = 99;
	assert elements[0].hunger == 7;
	const nested = elements[0].inner as Ptr<StoredInner>;
	view[] = { hunger: 20, name: "bb", inner: { v: 9, tags: [3] }, tags: [7, 8, 9] };
	assert elements[0].hunger == 20 && elements[0].name == "bb";
	assert elements[0].tags.length == 3 && elements[0].tags[2] == 9;
	assert nested.v == 9 && nested.tags[0] == 3;
}

test "valueLocations: reference dereference follows the same four value operations" {
	const owner: Ref<LocatedPet> = { hunger: 1, name: "a", inner: { v: 1, tags: [2] }, tags: [1, 2] };
	owner[].hunger = 2;
	owner[].feed(1);
	const snapshot = owner[];
	owner[] = { hunger: 40, name: "r", inner: { v: 2, tags: [] }, tags: [] };
	assert snapshot.hunger == 3;
	assert owner[].hunger == 40 && owner[].name == "r";
	assert owner[].inner.v == 2 && owner[].tags.length == 0;
}

test "valueLocations: sequence assignment preserves its location across equal grow shrink and empty lengths" {
	let values: Vec<int32> = [1, 2];
	const view = values as Ptr<Vec<int32>>;
	view[] = [7, 8];
	assert values.length == 2 && values[0] == 7 && values[1] == 8;
	view[] = [3, 4, 5];
	assert values.length == 3 && values[2] == 5;
	view[] = [9];
	assert values.length == 1 && view[][0] == 9;
	view[] = [];
	assert values.length == 0 && view[].length == 0;
	let bag: LocatedBag = { tags: [1], n: 0 };
	const field = bag.tags as Ptr<Vec<int32>>;
	bag = { tags: [4, 5, 6], n: 1 };
	assert field[].length == 3 && field[][1] == 5;
	assert bag.n == 1;
}

struct MovedNode { kids: Vec<int32>; }
struct MovedTree { nodes: Vec<MovedNode>; rows: Vec<Vec<int32>>; }
struct MovedForest { trees: Vec<MovedTree>; }
struct MovedHolder { kids: Vec<int32>; }

let movedIndexReads: int32 = 0;
function movedIndex(): int32 { movedIndexReads++; return 0; }
function movedTree(): MovedTree { return { nodes: [{ kids: [1, 2] }], rows: [[3, 4]] }; }
function movedForest(): MovedForest { return { trees: [movedTree()] }; }

function declNestedFromCall(): int32 {
	const kids = movedTree().nodes[movedIndex()].kids;
	return kids.length;
}
function declNestedFromLocal(): int32 {
	const tree = movedTree();
	const kids = tree.nodes[movedIndex()].kids;
	return kids.length;
}
function declOutermostFromLocal(): int32 {
	const tree = movedTree();
	const row = tree.rows[movedIndex()];
	return row.length;
}
function declMiddleFromLocal(): int32 {
	const forest = movedForest();
	const kids = forest.trees[movedIndex()].nodes[0].kids;
	return kids.length;
}
function declTwoIndices(): int32 {
	const forest = movedForest();
	const kids = forest.trees[movedIndex()].nodes[movedIndex()].kids;
	return kids.length;
}
function assignNestedToLocal(): int32 {
	const tree = movedTree();
	let kids: Vec<int32> = [9];
	kids = tree.nodes[movedIndex()].kids;
	return kids.length;
}
function assignNestedToField(): int32 {
	const tree = movedTree();
	let holder: MovedHolder = { kids: [9] };
	holder.kids = tree.nodes[movedIndex()].kids;
	return holder.kids.length;
}
function forOfNestedFromCall(): int32 {
	let sum: int32 = 0;
	for (const kid of movedTree().nodes[movedIndex()].kids) sum += kid;
	return sum;
}
function forOfMiddleFromCall(): int32 {
	let sum: int32 = 0;
	for (const kid of movedForest().trees[movedIndex()].nodes[0].kids) sum += kid;
	return sum;
}

test "valueLocations: a declaration moving out of an indexed path evaluates each index once" {
	movedIndexReads = 0;
	assert declNestedFromCall() == 2 && movedIndexReads == 1;
	movedIndexReads = 0;
	assert declNestedFromLocal() == 2 && movedIndexReads == 1;
	movedIndexReads = 0;
	assert declOutermostFromLocal() == 2 && movedIndexReads == 1;
	movedIndexReads = 0;
	assert declMiddleFromLocal() == 2 && movedIndexReads == 1;
	movedIndexReads = 0;
	assert declTwoIndices() == 2 && movedIndexReads == 2;
}

test "valueLocations: an assignment moving out of an indexed path evaluates each index once" {
	movedIndexReads = 0;
	assert assignNestedToLocal() == 2 && movedIndexReads == 1;
	movedIndexReads = 0;
	assert assignNestedToField() == 2 && movedIndexReads == 1;
}

test "valueLocations: a for-of over an indexed path of a fresh value evaluates each index once" {
	movedIndexReads = 0;
	assert forOfNestedFromCall() == 3 && movedIndexReads == 1;
	movedIndexReads = 0;
	assert forOfMiddleFromCall() == 3 && movedIndexReads == 1;
}

struct MovedPair { n: int32; kids: Vec<int32>; }
class MovedBox { kids: Vec<int32> = []; }
class MovedLink {
	v: int32;
	next: MovedLink | null = null;
	constructor(v: int32) { this.v = v; }
}

function movedChain(): MovedLink {
	const head = new MovedLink(1);
	const middle = new MovedLink(2);
	middle.next = new MovedLink(3);
	head.next = middle;
	return head;
}
function linkCount(head: MovedLink | null): int32 {
	let n: int32 = 0;
	let cur = head;
	while (cur != null) { n++; cur = cur.next; }
	return n;
}
function explicitSelfField(): int32 {
	let holder: MovedHolder = { kids: [1, 2] };
	holder.kids = move holder.kids;
	return holder.kids.length;
}
function explicitSelfElement(): int32 {
	let tree = movedTree();
	tree.nodes[0].kids = move tree.nodes[0].kids;
	return tree.nodes[0].kids.length;
}
function explicitDecl(): int32 {
	let tree = movedTree();
	const kids = move tree.nodes[movedIndex()].kids;
	return kids.length;
}
function explicitAssign(): int32 {
	let tree = movedTree();
	let kids: Vec<int32> = [9];
	kids = move tree.nodes[movedIndex()].kids;
	return kids.length;
}
function explicitReturn(): Vec<int32> {
	let tree = movedTree();
	return move tree.nodes[movedIndex()].kids;
}
function explicitTwoIndices(): int32 {
	let forest = movedForest();
	const kids = move forest.trees[movedIndex()].nodes[movedIndex()].kids;
	return kids.length;
}
function explicitLoopTotal(): int32 {
	let tree: MovedTree = { nodes: [{ kids: [1, 2] }, { kids: [3] }, { kids: [4, 5, 6] }], rows: [] };
	let total: int32 = 0;
	for (let i = 0; i < tree.nodes.length; i++) {
		const kids = move tree.nodes[i].kids;
		total += kids.length;
	}
	return total;
}
function explicitRefill(box: MovedBox): void {
	const kids = move box.kids;
	box.kids = [7, 8, 9];
}
function explicitAdvance(): int32 {
	let cur: MovedLink | null = movedChain();
	if (cur != null) cur = move cur.next;
	return linkCount(cur);
}
function explicitAdvanceReturned(): MovedLink | null {
	let cur: MovedLink | null = movedChain();
	if (cur != null) {
		cur = move cur.next;
		return cur;
	}
	return null;
}
function explicitWalk(): int32 {
	let cur: MovedLink | null = movedChain();
	let seen: int32 = 0;
	while (cur != null) {
		seen = seen * 10 + cur.v;
		cur = move cur.next;
	}
	return seen;
}
function explicitSiblingBefore(): int32 {
	let holder: MovedHolder = { kids: [1, 2, 3] };
	const pair: MovedPair = { n: holder.kids.length, kids: move holder.kids };
	return pair.n * 10 + pair.kids.length;
}
function explicitAfterThrow(fail: boolean): int32 {
	let tree = movedTree();
	if (fail) throw new Error("before the move");
	const kids = move tree.nodes[movedIndex()].kids;
	return kids.length;
}

test "valueLocations: an explicit move into its own field path keeps the value" {
	assert explicitSelfField() == 2;
	assert explicitSelfElement() == 2;
}

test "valueLocations: an explicit move out of an indexed path evaluates each index once" {
	movedIndexReads = 0;
	assert explicitDecl() == 2 && movedIndexReads == 1;
	movedIndexReads = 0;
	assert explicitAssign() == 2 && movedIndexReads == 1;
	movedIndexReads = 0;
	assert explicitReturn().length == 2 && movedIndexReads == 1;
	movedIndexReads = 0;
	assert explicitTwoIndices() == 2 && movedIndexReads == 2;
}

test "valueLocations: an explicit move in a counted loop leaves the next element in place" {
	assert explicitLoopTotal() == 6;
}

test "valueLocations: a field path written after an explicit move keeps the new value" {
	const box = new MovedBox();
	box.kids = [1, 2];
	explicitRefill(box);
	assert box.kids.length == 3 && box.kids[0] == 7;
}

test "valueLocations: an explicit move of a next link advances a linked list" {
	assert explicitAdvance() == 2;
	assert linkCount(explicitAdvanceReturned()) == 2;
	assert explicitWalk() == 123;
}

test "valueLocations: a sibling read before an explicit move in one literal sees the value" {
	assert explicitSiblingBefore() == 33;
}

test "valueLocations: a throw before an explicit move never evaluates the moved path" {
	movedIndexReads = 0;
	let caught = false;
	try { explicitAfterThrow(true); } catch (e) { caught = true; }
	assert caught && movedIndexReads == 0;
	assert explicitAfterThrow(false) == 2 && movedIndexReads == 1;
}
