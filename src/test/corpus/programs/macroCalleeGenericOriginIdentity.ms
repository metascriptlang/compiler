// @stdout: canonical identity true true true true rows fake 3
import {
	BlockStmtData,
	BooleanLiteralData,
	CallExprData,
	FunctionDeclData,
	Node,
	NodeKind,
	ReturnStmtData,
	Symbol,
	createNodeAt,
	error,
	getImpl,
} from "std/meta";

struct Row { field: string; }
struct OtherRow { field: string; }
class Table<T> { name: string; }
class OtherTable<T> { name: string; }

function where<T>(this table: Table<T>, predicate: (row: T) => boolean): string {
	return table.name;
}
function where<T>(this table: OtherTable<T>, predicate: (row: T) => boolean): string {
	return table.name;
}

const table = new Table<Row>("rows");
const table2 = new Table<OtherRow>("other rows");
const other = new OtherTable<Row>("fake");

function real1(value: string): string {
	return table.where((row: Row) => row.field == value);
}
function real2(value: string): string {
	return table2.where((row: OtherRow) => row.field == value);
}
function fake(value: string): string {
	return other.where((row: Row) => row.field == value);
}

macro requireIdentity(a: Node, b: Node, expected: Node): Node {
	if (expected.kind != NodeKind.BooleanLiteral) { error("expected boolean", expected); }
	let left: Symbol | null = null;
	for (const fn of [a, b]) {
		const declaration = getImpl(fn);
		if (declaration === null || declaration.kind != NodeKind.FunctionDecl) {
			error("expected function", fn);
		}
		const body = (declaration as FunctionDeclData).fnBody;
		if (body.kind != NodeKind.BlockStmt) { error("expected block", body); }
		const statements = (body as BlockStmtData).statements;
		if (statements.length != 1 || statements[0].kind != NodeKind.ReturnStmt) {
			error("expected one return", body);
		}
		const returned = (statements[0] as ReturnStmtData).argument;
		if (returned === null || returned.kind != NodeKind.CallExpr) {
			error("expected call", body);
		}
		const callee = (returned as CallExprData).callee;
		const symbol = callee.resolvedSym;
		if (symbol === null) { error("callee unresolved", callee); }
		let root: Symbol = symbol;
		while (true) {
			const parent = root.instantiatedFrom;
			if (parent === null) { break; }
			root = parent;
		}
		if (left === null) {
			left = root;
		} else {
			const same = left.itemModule == root.itemModule && left.item == root.item;
			if (same != (expected as BooleanLiteralData).boolValue) {
				error("wrong canonical identity: left=" + String(left.itemModule) +
					":" + String(left.item) + " right=" + String(root.itemModule) +
					":" + String(root.item), b);
			}
		}
	}
	return createNodeAt(NodeKind.BooleanLiteral, { boolValue: true }, a.location);
}

function pick<T>(items: T[]): string { return `${items[0]}`; }
function pickLast<T>(items: T[]): string { return `${items[items.length - 1]}`; }
function freeA(value: string): string {
	return pick<string>([value]);
}
function freeB(value: string): string {
	return pick<int32>([value.length]);
}
function freeC(value: string): string {
	return pickLast<string>([value]);
}

const same = requireIdentity(real1, real2, true);
const different = requireIdentity(real1, fake, false);
const freeSame = requireIdentity(freeA, freeB, true);
const freeDifferent = requireIdentity(freeA, freeC, false);
console.log("canonical identity", same, different, freeSame, freeDifferent, real1("x"), fake("y"), freeB("abc"));
