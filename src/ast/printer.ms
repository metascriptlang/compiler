// AST Printer - generic debug dump driven by the shared per-kind field spec
// (ast/fieldspec.ms). Every payload field prints as `name: value` lines;
// completeness is inherited from the spec — new NodeData fields show up here
// with zero printer changes. This replaced a curated 700-line per-kind
// pretty-printer: the old format showed a hand-picked subset of fields; this
// one shows everything (it's a completeness-first debug dumper — the fmt
// printer is the pretty-printer and lives in compiler/fmt/printer).

import { Node, Type, SourceLocation } from "./node";
import { FieldSink, nodeFields, nodeKindName } from "./fieldspec";

function indent(level: int32): string {
	let spaces = "";
	for (let i = 0; i < level; i++) spaces = spaces + "  ";
	return spaces;
}

// Module-level recursion level for the sink (debug CLI tool, not reentrant).
let _level = 0;

function pad(): string {
	return indent(_level);
}

function printFieldNode(name: string, n: Node | null): void {
	if (n === null) {
		console.log(`${pad()}${name}: null`);
		return;
	}
	console.log(`${pad()}${name}:`);
	const saved = _level;
	_level = saved + 1;
	printNode(n, _level);
	_level = saved;
}

const printSink: FieldSink = {
	node: (name: string, n: Node | null): void => { printFieldNode(name, n); },
	nodes: (name: string, a: (Node | null)[] | null): void => {
		if (a === null || a.length === 0) {
			console.log(`${pad()}${name}: []`);
			return;
		}
		console.log(`${pad()}${name}: (${a.length})`);
		const saved = _level;
		_level = saved + 1;
		for (const x of a) {
			if (x === null) {
				console.log(`${pad()}null`);
			} else {
				printNode(x, _level);
			}
		}
		_level = saved;
	},
	nodesNested: (name: string, a: (Node | null)[][] | null): void => {
		if (a === null || a.length === 0) {
			console.log(`${pad()}${name}: []`);
			return;
		}
		console.log(`${pad()}${name}: (${a.length} rows)`);
		const saved = _level;
		_level = saved + 1;
		for (const row of a) {
			if (row === null || row.length === 0) {
				console.log(`${pad()}-`);
			} else {
				for (const x of row) {
					if (x === null) {
						console.log(`${pad()}null`);
					} else {
						printNode(x, _level);
					}
				}
			}
		}
		_level = saved;
	},
	typ: (name: string, t: Type | null): void => {
		console.log(`${pad()}${name}: ${t === null ? "null" : `${t.kind as number}:${t.typeName}`}`);
	},
	str: (name: string, s: string): void => { console.log(`${pad()}${name}: ${s}`); },
	strArr: (name: string, a: string[] | null): void => {
		console.log(`${pad()}${name}: ${a === null ? "null" : a.join(", ")}`);
	},
	integer: (name: string, v: int64): void => { console.log(`${pad()}${name}: ${v}`); },
	float: (name: string, v: float64): void => { console.log(`${pad()}${name}: ${v}`); },
	bool: (name: string, b: boolean): void => { console.log(`${pad()}${name}: ${b ? "true" : "false"}`); },
	loc: (name: string, l: SourceLocation | null): void => {
		if (l === null) {
			console.log(`${pad()}${name}: null`);
		} else {
			console.log(`${pad()}${name}: ${l.line}:${l.column}-${l.endLine}:${l.endColumn}`);
		}
	},
	locs: (name: string, l: SourceLocation[] | null): void => {
		if (l === null || l.length === 0) {
			console.log(`${pad()}${name}: []`);
			return;
		}
		let s = "";
		for (const x of l) s = s + (s === "" ? "" : ", ") + `${x.line}:${x.column}`;
		console.log(`${pad()}${name}: ${s}`);
	},
	floats: (name: string, a: number[] | null): void => {
		if (a === null || a.length === 0) {
			console.log(`${pad()}${name}: []`);
			return;
		}
		let s = "";
		for (const v of a) s = s + (s === "" ? "" : ", ") + `${v}`;
		console.log(`${pad()}${name}: ${s}`);
	},
};

export function printNode(node: Node | null, level: int32): void {
	if (node === null) return;
	const saved = _level;
	_level = level;
	const loc = node.location;
	console.log(`${indent(level)}${nodeKindName(node.kind)} [${loc.line}:${loc.column}-${loc.endLine}:${loc.endColumn}] f=${node.flags}${node.typeArg === "" ? "" : ` ta=${node.typeArg}`}`);
	nodeFields(node, printSink);
	_level = saved;
}
