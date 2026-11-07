import { Node, NodeKind, NodeData, ProgramData, ClassDeclData, createNodeAt, makeLoc } from "../ast/node";

// The statements of a module and the members of a class are the units a check takes out one at a time.
// While its owner is in check, its list lives here instead of in the owner node, so a reader that holds
// the owner through a key reaches the list only through stmtsOf or membersOf.
let _inCheck: HashMap<Node, Node[]> = new HashMap<Node, Node[]>();

export function takeUnits(owner: Node): Node[] {
	if (_inCheck.has(owner)) throw new Error(`internal: a ${owner.kind} taken into check twice`);
	const units = ownList(owner);
	_inCheck.set(owner, units);
	setOwnList(owner, []);
	return units;
}

export function putUnits(owner: Node, units: Node[]): void {
	if (_inCheck.get(owner) != units) throw new Error("internal: putUnits returned a list its owner did not take");
	_inCheck.delete(owner);
	setOwnList(owner, units);
}

export function stmtsOf(program: Node): Node[] {
	if (program.kind != NodeKind.Program) throw new Error(`internal: stmtsOf a ${program.kind}`);
	return unitsOf(program);
}

export function membersOf(cls: Node): Node[] {
	if (cls.kind != NodeKind.ClassDecl) throw new Error(`internal: membersOf a ${cls.kind}`);
	return unitsOf(cls);
}

function unitsOf(owner: Node): Node[] {
	const taken = _inCheck.get(owner);
	return taken != null ? taken : ownList(owner);
}

function ownList(owner: Node): Node[] {
	match (owner.kind) {
		NodeKind.Program => { return (owner.data as ProgramData).programStmts; },
		NodeKind.ClassDecl => { return (owner.data as ClassDeclData).classBody; },
		_ => { throw new Error(`internal: a ${owner.kind} owns no units`); },
	};
}

function setOwnList(owner: Node, units: Node[]): void {
	match (owner.kind) {
		NodeKind.Program => { (owner.data as ProgramData).programStmts = units; },
		NodeKind.ClassDecl => { (owner.data as ClassDeclData).classBody = units; },
		_ => { throw new Error(`internal: a ${owner.kind} owns no units`); },
	};
}

function programOf(stmts: Node[]): Node {
	return createNodeAt(NodeKind.Program, { programStmts: stmts } as NodeData, makeLoc(1, 1));
}

test "a program in check shows its statements through stmtsOf and none in its own node" {
	const a = programOf([]);
	const b = programOf([a]);
	const units = takeUnits(b);
	assert (b.data as ProgramData).programStmts.length == 0;
	assert stmtsOf(b).length == 1 && stmtsOf(b)[0] == a;
	putUnits(b, units);
	assert (b.data as ProgramData).programStmts.length == 1;
	assert stmtsOf(b) == (b.data as ProgramData).programStmts;
}
