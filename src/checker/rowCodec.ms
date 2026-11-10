import { Symbol, SymbolFlag, NodeFlag, SymbolKind, SymbolState, Type, TypeKind, TypeFlag, Node, NodeData, NodeKind, SourceLocation, CallingConvention, makeLoc, makeLocRange, createNodeAt, DeclKind, ExternKind, BuiltinKind, FlowNode, InlineFrame, backEdges, strongNodes, ForStmtData, ForOfStmtData, ForInStmtData, DoWhileStmtData, SwitchStmtData, InterfaceDeclData, EnumDeclData } from "../ast/node";
import { FieldSink, nodeFields } from "../ast/fieldspec";
import { emptyType, wellKnownTypes, getSysType, createResult } from "./types";
import { makeSymbolState, builtinKindName, builtinKindNamed } from "./symbol";

// ===== Escaping =====
// Fields are tab-separated, comma-joined lists. Escape: \\ \n \r \t , so no
// raw separator can appear inside a value.

function hexDigitByte(v: int32): uint8 {
	return (v < 10 ? 48 + v : 87 + v) as uint8;
}

function hexValByte(c: int32): int32 {
	if (c >= 48 && c <= 57) return c - 48;
	if (c >= 97 && c <= 102) return c - 87;
	if (c >= 65 && c <= 70) return c - 55;
	return 0;
}

// Escapes the separators AND every byte >= 0x80 (as \xHH). The non-ASCII
// escape is a PERFORMANCE invariant, not cosmetics: it makes the whole pack
// pure ASCII, which is what lets the reader use the character-indexed string
// ops (indexOf/slice). On a non-ASCII string those re-walk the UTF-8 from the
// start on every call (runtime/core/string.c), so scanning a 2 MB blob with
// them is quadratic — that is what hung the loader before. 97 std files carry
// non-ASCII bytes, so the payload is never accidentally ASCII.
export function escapeP(s: string): string {
	if (s == "") return "";
	const b = s.asBytes();
	const out: uint8[] = [];
	let i = 0;
	while (i < b.length) {
		const c = b[i] as int32;
		if (c == 92) { out.push(92); out.push(92); }
		else if (c == 10) { out.push(92); out.push(110); }
		else if (c == 13) { out.push(92); out.push(114); }
		else if (c == 9) { out.push(92); out.push(116); }
		else if (c == 44) { out.push(92); out.push(99); }
		else if (c >= 128) {
			out.push(92);
			out.push(120);
			out.push(hexDigitByte((c / 16) as int32));
			out.push(hexDigitByte((c % 16) as int32));
		} else out.push(c as uint8);
		i = i + 1;
	}
	return out.asString();
}

export function unescapeP(s: string): string {
	if (s == "") return "";
	// Early-out BEFORE asBytes: the pack is ASCII, so indexOf takes the runtime's
	// memcmp path, while asBytes copies the whole field into a fresh uint8[].
	// Most fields carry no escape at all, and the reader unescapes ~400k of them.
	if (s.indexOf("\\", 0) < 0) return s;
	const b = s.asBytes();
	const out: uint8[] = [];
	let i = 0;
	while (i < b.length) {
		const c = b[i] as int32;
		if (c == 92 && i + 1 < b.length) {
			const n = b[i + 1] as int32;
			if (n == 110) { out.push(10); i = i + 2; continue; }
			if (n == 114) { out.push(13); i = i + 2; continue; }
			if (n == 116) { out.push(9); i = i + 2; continue; }
			if (n == 99) { out.push(44); i = i + 2; continue; }
			if (n == 120 && i + 3 < b.length) {
				const hi = hexValByte(b[i + 2] as int32);
				const lo = hexValByte(b[i + 3] as int32);
				out.push(((hi * 16) + lo) as uint8);
				i = i + 4;
				continue;
			}
			out.push(n as uint8);
			i = i + 2;
			continue;
		}
		out.push(c as uint8);
		i = i + 1;
	}
	return out.asString();
}

export function joinCsv(items: string[]): string {
	if (items.length == 0) return "-";
	let out = "";
	let i = 0;
	while (i < items.length) {
		if (i > 0) out = out + ",";
		out = out + escapeP(items[i]);
		i = i + 1;
	}
	return out;
}

export function splitCsv(s: string): string[] {
	if (s == "-") return [];
	const out: string[] = [];
	let start = 0;
	let i = 0;
	const n = s.length;
	while (i < n) {
		const c = s.charCodeAt(i);
		if (c == 92) {
			i = i + 2;
			continue;
		}
		if (c == 44) {
			out.push(unescapeP(s.slice(start, i)));
			start = i + 1;
		}
		i = i + 1;
	}
	if (n > start || out.length > 0) out.push(unescapeP(s.slice(start, n)));
	return out;
}

export function intsCsv(arr: int32[]): string {
	if (arr.length == 0) return "-";
	let out = "";
	let i = 0;
	while (i < arr.length) {
		if (i > 0) out = out + ",";
		out = out + arr[i];
		i = i + 1;
	}
	return out;
}

export function strListText(items: string[] | null): string {
	if (items == null) return "-";
	const parts: string[] = [];
	for (const item of items) parts.push(escapeP(item));
	return `${items.length}:${parts.join(",")}`;
}

export function intListText(items: int32[] | null): string {
	if (items == null) return "-";
	const parts: string[] = [];
	for (const item of items) parts.push(`${item}`);
	return `${items.length}:${parts.join(",")}`;
}

function floatListText(items: number[]): string {
	const parts: string[] = [];
	for (const item of items) parts.push(`${item}`);
	return `${items.length}:${parts.join(",")}`;
}

function locText(l: SourceLocation | null): string {
	if (l == null) return "-";
	return `${l.line}/${l.column}/${l.endLine}/${l.endColumn}`;
}

function locListText(locs: SourceLocation[] | null): string {
	if (locs == null) return "-";
	const parts: string[] = [];
	for (const l of locs) parts.push(locText(l));
	return `${locs.length}:${parts.join(",")}`;
}

function nullListError(owner: string, field: string): Error {
	return new Error(`internal: ${owner} holds null in '${field}', a list whose type holds no null`);
}

function nodeOwner(i: int32, n: Node): string {
	return `node ${i} (${n.kind.toString()})`;
}

// Writer-side node/type index views for the top-level payload emitter —
// emitObjectRows assigns the writer's maps here before emitting N rows.
let _wnodeIdx = new HashMap<Node, int32>();
let _wtypeIdx = new HashMap<Type, int32>();

function idxNodeP(n: Node | null): int32 {
	if (n == null || !_wnodeIdx.has(n)) return -1;
	const v = _wnodeIdx.get(n);
	return v == null ? -1 : v;
}

function idxTypeP(t: Type | null): int32 {
	if (t == null || !_wtypeIdx.has(t)) return -1;
	const v = _wtypeIdx.get(t);
	return v == null ? -1 : v;
}

function idxsP(arr: Node[] | null): string {
	if (arr == null) return "-";
	const ids: int32[] = [];
	for (const n of arr) ids.push(idxNodeP(n));
	return intListText(ids);
}

function nestedIdxsP(rows: Node[][]): string {
	const parts: string[] = [];
	for (const row of rows) parts.push(idxsP(row));
	return `${parts.length}:${parts.join(";")}`;
}

function strongOrNull(arr: Unowned<Node>[] | null): Node[] | null {
	return arr == null ? null : strongNodes(arr);
}

function strongRows(rows: Unowned<Node>[][]): Node[][] {
	const out: Node[][] = [];
	for (const row of rows) out.push(strongNodes(row));
	return out;
}

function nullRowPath<T>(rows: T[][] | null): string | null {
	if (rows == null) return "";
	for (let k = 0; k < rows.length; k += 1) {
		if (rows[k] == null) return `[${k}]`;
	}
	return null;
}

// Emit-phase sink: appends each field's serialized column.
let _payloadCols: string[] = [];
let _payloadAt: int32 = -1;
let _payloadNode: Node | null = null;

function payloadNullList(field: string): Error {
	return nullListError(nodeOwner(_payloadAt, _payloadNode!), field);
}

const emitSink: FieldSink = {
	node: (name: string, x: Node | null): void => { _payloadCols.push(`${idxNodeP(x)}`); },
	nodes: (name: string, a: Node[] | null): void => {
		if (a == null) throw payloadNullList(name);
		_payloadCols.push(idxsP(a));
	},
	nodesNested: (name: string, a: Node[][] | null): void => {
		const missing = nullRowPath(a);
		if (missing != null) throw payloadNullList(name + missing);
		_payloadCols.push(nestedIdxsP(a!));
	},
	typ: (name: string, t: Type | null): void => { _payloadCols.push(`${idxTypeP(t)}`); },
	str: (name: string, s: string): void => { _payloadCols.push(escapeP(s)); },
	strArr: (name: string, a: string[] | null): void => {
		if (a == null) throw payloadNullList(name);
		_payloadCols.push(strListText(a));
	},
	integer: (name: string, v: int64): void => { _payloadCols.push(`${v}`); },
	float: (name: string, v: float64): void => { _payloadCols.push(`${v}`); },
	bool: (name: string, b: boolean): void => { _payloadCols.push(b ? "1" : "0"); },
	loc: (name: string, l: SourceLocation | null): void => { _payloadCols.push(locText(l)); },
	locs: (name: string, l: SourceLocation[] | null): void => {
		if (l == null) throw payloadNullList(name);
		_payloadCols.push(locListText(l));
	},
	floats: (name: string, a: number[] | null): void => {
		if (a == null) throw payloadNullList(name);
		_payloadCols.push(floatListText(a));
	},
};

function emitNodePayloadViaSink(at: int32, n: Node): string {
	_payloadCols = [];
	_payloadAt = at;
	_payloadNode = n;
	nodeFields(n, emitSink);
	return _payloadCols.join("\t");
}

// ===== Reader =====

// In-place reader for every pack and deps row: fields are read as bytes at an offset, so a number
// allocates nothing and a string is sliced only where the loaded object stores it. A field that
// is not what its column holds sets `bad`, and the loader answers with a miss.
export class PackReader {
	b: uint8[];
	s: string;
	pos: int32 = 0;
	last: int32 = 10;
	bad: boolean = false;

	constructor(s: string) {
		this.s = s;
		this.b = [...s.asBytes()];
	}
}

export function fieldEnd(this r: PackReader): int32 {
	let i = r.pos;
	const n = r.b.length;
	while (i < n) {
		const c = r.b[i] as int32;
		if (c == 9 || c == 10) break;
		i += 1;
	}
	return i;
}

export function finish(this r: PackReader, end: int32): void {
	if (end >= r.b.length) {
		r.last = 10;
		r.pos = end;
		return;
	}
	r.last = r.b[end] as int32;
	r.pos = end + 1;
}

// Returns the tag byte of the next row, or -1 at the end of the pack. Empty lines are skipped.
export function startRow(this r: PackReader): int32 {
	const n = r.b.length;
	while (r.pos < n && r.b[r.pos] == 10) r.pos += 1;
	if (r.pos >= n) return -1;
	const tag = r.b[r.pos] as int32;
	r.pos += 1;
	r.last = 9;
	if (r.pos < n && r.b[r.pos] != 9 && r.b[r.pos] != 10) r.bad = true;
	r.finish(r.pos);
	return tag;
}

export function endRow(this r: PackReader): void {
	while (r.last == 9) r.finish(r.fieldEnd());
}

export function skip(this r: PackReader): void {
	if (r.last != 9) {
		r.bad = true;
		return;
	}
	r.finish(r.fieldEnd());
}

export function int(this r: PackReader): int64 {
	if (r.last != 9) {
		r.bad = true;
		return 0;
	}
	const n = r.b.length;
	let i = r.pos;
	const negative = i < n && r.b[i] == 45;
	if (negative) i += 1;
	const digits = i;
	const limit: uint64 = negative ? 9223372036854775808 : 9223372036854775807;
	let value: uint64 = 0;
	while (i < n) {
		const d = (r.b[i] as int32) - 48;
		if (d < 0 || d > 9) break;
		if (value > (limit - (d as uint64)) / 10) r.bad = true;
		else value = value * 10 + (d as uint64);
		i += 1;
	}
	if (i == digits || (i < n && r.b[i] != 9 && r.b[i] != 10)) r.bad = true;
	r.finish(i);
	if (!negative) return value as int64;
	return value == 0 ? 0 : -((value - 1) as int64) - 1;
}

export function str(this r: PackReader): string {
	if (r.last != 9) {
		r.bad = true;
		return "";
	}
	const end = r.fieldEnd();
	const text = end > r.pos ? r.s.byteSlice(r.pos, end) : "";
	r.finish(end);
	return text;
}

export function text(this r: PackReader): string {
	return unescapeP(r.str());
}

export function flag(this r: PackReader): boolean {
	const n = r.b.length;
	const yes = r.last == 9 && r.pos < n && r.b[r.pos] == 49 && (r.pos + 1 == n || r.b[r.pos + 1] == 9 || r.b[r.pos + 1] == 10);
	r.skip();
	return yes;
}

export function dec(this r: PackReader): int32 {
	return r.int() as int32;
}

export function nodeRef(this r: PackReader, nodes: Node[]): Node | null {
	const v = r.int();
	return v >= 0 && v < nodes.length ? nodes[v as int32] : null;
}

export function typeRef(this r: PackReader, types: Type[]): Type | null {
	const v = r.int();
	return v >= 0 && v < types.length ? types[v as int32] : null;
}

function expect(this r: PackReader, c: int32, end: int32): void {
	if (r.pos < end && (r.b[r.pos] as int32) == c) r.pos += 1;
	else r.bad = true;
}

function intAt(this r: PackReader, end: int32): int32 {
	const negative = r.pos < end && r.b[r.pos] == 45;
	if (negative) r.pos += 1;
	const digits = r.pos;
	let value: int64 = 0;
	while (r.pos < end) {
		const d = (r.b[r.pos] as int32) - 48;
		if (d < 0 || d > 9) break;
		value = value * 10 + (d as int64);
		if (value > 2147483648) {
			r.bad = true;
			return 0;
		}
		r.pos += 1;
	}
	if (r.pos == digits || (!negative && value > 2147483647)) {
		r.bad = true;
		return 0;
	}
	return (negative ? -value : value) as int32;
}

// -1 for the null mark "-"; otherwise the count before ':', with pos after it.
function listHead(this r: PackReader, end: int32): int32 {
	if (end == r.pos + 1 && r.b[r.pos] == 45) {
		r.pos = end;
		return -1;
	}
	const digits = r.pos;
	let count: int32 = 0;
	while (r.pos < end && count <= end - digits) {
		const d = (r.b[r.pos] as int32) - 48;
		if (d < 0 || d > 9) break;
		count = count * 10 + d;
		r.pos += 1;
	}
	if (r.pos == digits) r.bad = true;
	r.expect(58, end);
	if (count > end - r.pos + 1) r.bad = true;
	return r.bad ? -1 : count;
}

function intsUntil(this r: PackReader, end: int32): int32[] | null {
	const count = r.listHead(end);
	if (count < 0) return null;
	const out: int32[] = [];
	for (let k = 0; k < count && !r.bad; k += 1) {
		if (k > 0) r.expect(44, end);
		out.push(r.intAt(end));
	}
	if (r.pos != end) r.bad = true;
	return out;
}

function rawItems(this r: PackReader, end: int32): string[] | null {
	const count = r.listHead(end);
	if (count < 0) return null;
	const out: string[] = [];
	let start = r.pos;
	for (let i = r.pos; i < end; i += 1) {
		if (r.b[i] != 44) continue;
		out.push(i > start ? r.s.byteSlice(start, i) : "");
		start = i + 1;
	}
	if (count > 0) out.push(end > start ? r.s.byteSlice(start, end) : "");
	else if (end > r.pos) r.bad = true;
	if (out.length != count) r.bad = true;
	return out;
}

function locAt(this r: PackReader, end: int32): SourceLocation | null {
	if (r.pos < end && r.b[r.pos] == 45 && (r.pos + 1 == end || r.b[r.pos + 1] == 44)) {
		r.pos += 1;
		return null;
	}
	const line = r.intAt(end);
	r.expect(47, end);
	const column = r.intAt(end);
	r.expect(47, end);
	const endLine = r.intAt(end);
	r.expect(47, end);
	return makeLocRange(line, column, endLine, r.intAt(end));
}

export function nullableInts(this r: PackReader): int32[] | null {
	if (r.last != 9) {
		r.bad = true;
		return null;
	}
	const end = r.fieldEnd();
	const out = r.intsUntil(end);
	r.finish(end);
	return out;
}

export function intList(this r: PackReader): int32[] {
	const out = r.nullableInts();
	if (out != null) return out;
	r.bad = true;
	return [];
}

export function nullableStrs(this r: PackReader): string[] | null {
	if (r.last != 9) {
		r.bad = true;
		return null;
	}
	const end = r.fieldEnd();
	const raw = r.rawItems(end);
	r.finish(end);
	if (raw == null) return null;
	const out: string[] = [];
	for (const item of raw) out.push(unescapeP(item));
	return out;
}

export function strList(this r: PackReader): string[] {
	const out = r.nullableStrs();
	if (out != null) return out;
	r.bad = true;
	return [];
}

export function floatList(this r: PackReader): number[] {
	if (r.last != 9) {
		r.bad = true;
		return [];
	}
	const end = r.fieldEnd();
	const raw = r.rawItems(end);
	r.finish(end);
	const out: number[] = [];
	if (raw == null) {
		r.bad = true;
		return out;
	}
	for (const item of raw) {
		if (item == "") r.bad = true;
		out.push(item.parseFloat());
	}
	return out;
}

export function location(this r: PackReader): SourceLocation | null {
	if (r.last != 9) {
		r.bad = true;
		return null;
	}
	const end = r.fieldEnd();
	const l = r.locAt(end);
	if (r.pos != end) r.bad = true;
	r.finish(end);
	return l;
}

export function nullableLocs(this r: PackReader): SourceLocation[] | null {
	if (r.last != 9) {
		r.bad = true;
		return null;
	}
	const end = r.fieldEnd();
	const count = r.listHead(end);
	let out: SourceLocation[] | null = null;
	if (count >= 0) {
		const locs: SourceLocation[] = [];
		for (let k = 0; k < count && !r.bad; k += 1) {
			if (k > 0) r.expect(44, end);
			locs.push(r.locAt(end) as SourceLocation);
		}
		if (r.pos != end) r.bad = true;
		out = locs;
	}
	r.finish(end);
	return out;
}

export function locList(this r: PackReader): SourceLocation[] {
	const out = r.nullableLocs();
	if (out != null) return out;
	r.bad = true;
	return [];
}

export function idRows(this r: PackReader): int32[][] {
	const rows: int32[][] = [];
	if (r.last != 9) {
		r.bad = true;
		return rows;
	}
	const end = r.fieldEnd();
	const count = r.listHead(end);
	if (count < 0) r.bad = true;
	for (let k = 0; k < count && !r.bad; k += 1) {
		if (k > 0) r.expect(59, end);
		let rowEnd = r.pos;
		while (rowEnd < end && r.b[rowEnd] != 59) rowEnd += 1;
		const row = r.intsUntil(rowEnd);
		if (row == null) r.bad = true;
		else rows.push(row);
	}
	if (r.pos != end) r.bad = true;
	r.finish(end);
	return rows;
}

function refsFit(ids: int32[] | null, count: int32, allowNone: boolean): boolean {
	if (ids == null) return true;
	const least = allowNone ? -1 : 0;
	for (const k of ids) {
		if (k < least || k >= count) return false;
	}
	return true;
}

function nodesAt(ids: int32[], nodes: Node[]): Node[] {
	const out: Node[] = [];
	for (const k of ids) out.push(k >= 0 ? nodes[k] : null as unknown as Node);
	return out;
}

function optionalNodesAt(ids: int32[], nodes: Node[]): (Node | null)[] {
	const out: (Node | null)[] = [];
	for (const k of ids) out.push(k >= 0 ? nodes[k] : null);
	return out;
}

function typesAt(ids: int32[], types: Type[]): Type[] {
	const out: Type[] = [];
	for (const k of ids) out.push(types[k]);
	return out;
}

function symsAt(ids: int32[], syms: Symbol[]): Symbol[] {
	const out: Symbol[] = [];
	for (const k of ids) out.push(syms[k]);
	return out;
}

export function nodeList(this r: PackReader, nodes: Node[]): Node[] {
	const ids = r.intList();
	if (refsFit(ids, nodes.length, true)) return nodesAt(ids, nodes);
	r.bad = true;
	return [];
}

export function nodeRows(this r: PackReader, nodes: Node[]): Node[][] {
	const out: Node[][] = [];
	for (const ids of r.idRows()) {
		if (!refsFit(ids, nodes.length, true)) {
			r.bad = true;
			return [];
		}
		out.push(nodesAt(ids, nodes));
	}
	return out;
}

// The table rows' index lists: "-" and "" are the empty list, anything after a number is skipped.
export function ints(this r: PackReader): int32[] {
	const out: int32[] = [];
	if (r.last != 9) {
		r.bad = true;
		return out;
	}
	const end = r.fieldEnd();
	let i = r.pos;
	if (end == i || (end == i + 1 && r.b[i] == 45)) {
		r.finish(end);
		return out;
	}
	while (i < end) {
		let neg = false;
		if (r.b[i] == 45) {
			neg = true;
			i += 1;
		}
		let v: int32 = 0;
		while (i < end) {
			const d = (r.b[i] as int32) - 48;
			if (d < 0 || d > 9) break;
			v = v * 10 + d;
			i += 1;
		}
		out.push(neg ? -v : v);
		i += 1;
	}
	r.finish(end);
	return out;
}

function nd(i: int32, nodes: Node[]): Node | null {
	return i >= 0 && i < nodes.length ? nodes[i] : null;
}

// Mirror of emitNodePayload — same kinds, same field order. `f` holds the
// payload fields of the N row (everything after the common header).
function buildNodeData(kind: NodeKind, rd: PackReader, nodes: Node[], types: Type[]): NodeData {
	if (kind == NodeKind.NumberLiteral) {
		const isFloat = rd.flag();
		const value = rd.str().parseFloat();
		return { value, isFloat, intVal: rd.int(), outOfRangeText: rd.text(), isBitPattern: rd.flag() } as NodeData;
	}
	if (kind == NodeKind.StringLiteral) return { value: rd.text() } as NodeData;
	if (kind == NodeKind.BooleanLiteral) return { boolValue: rd.flag() } as NodeData;
	if (kind == NodeKind.NullLiteral) return { nullPlaceholder: true } as NodeData;
	if (kind == NodeKind.BigIntLiteral) return { bigintValue: rd.text() } as NodeData;
	if (kind == NodeKind.RegexLiteral) return { regexPattern: rd.text() } as NodeData;
	if (kind == NodeKind.Identifier) return { name: rd.text() } as NodeData;
	if (kind == NodeKind.BinaryExpr) return { operator: rd.text(), left: rd.nodeRef(nodes) as Node, right: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.UnaryExpr) return { unaryOp: rd.text(), operand: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.UpdateExpr) return { updateOp: rd.text(), updateArg: rd.nodeRef(nodes) as Node, isPrefix: rd.flag() } as NodeData;
	if (kind == NodeKind.CallExpr) return { callee: rd.nodeRef(nodes) as Node, arguments: rd.nodeList(nodes), isDirectCall: rd.flag(), resolvedOverloadIdx: rd.str().parseFloat() } as NodeData;
	if (kind == NodeKind.MemberExpr) return { object: rd.nodeRef(nodes) as Node, property: rd.text(), isOptional: rd.flag() } as NodeData;
	if (kind == NodeKind.ArrayAccess) return { array: rd.nodeRef(nodes) as Node, index: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.ObjectLiteral) return { properties: rd.nodeList(nodes), keys: rd.strList(), keyLocations: rd.locList() } as NodeData;
	if (kind == NodeKind.ArrayLiteral) return { elements: rd.nodeList(nodes) } as NodeData;
	if (kind == NodeKind.ArrowFunction) return { arrowParams: rd.strList(), arrowParamTypes: rd.strList(), arrowBody: rd.nodeRef(nodes) as Node, arrowFlags: rd.text(), arrowReturnType: rd.text(), arrowDefaults: rd.nodeList(nodes) } as NodeData;
	if (kind == NodeKind.FunctionExpr) return { funcExprParams: rd.strList(), funcExprParamTypes: rd.strList(), funcExprBody: rd.nodeRef(nodes) as Node, funcExprFlags: rd.text(), funcExprReturnType: rd.text() } as NodeData;
	if (kind == NodeKind.TypeAssertion) return { asExpr: rd.nodeRef(nodes) as Node, asType: rd.text() } as NodeData;
	if (kind == NodeKind.ConditionalExpr) return { ternaryCondition: rd.nodeRef(nodes) as Node, ternaryConsequent: rd.nodeRef(nodes) as Node, ternaryAlternate: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.SpreadExpr) return { spreadArg: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.NewExpr) return { newCallee: rd.nodeRef(nodes) as Node, newArguments: rd.nodeList(nodes) } as NodeData;
	if (kind == NodeKind.TryExpr) return { tryArg: rd.nodeRef(nodes) as Node, hasCatch: rd.flag(), catchVal: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.MatchExpr) return { matchDisc: rd.nodeRef(nodes) as Node, matchCases: rd.nodeList(nodes) } as NodeData;
	if (kind == NodeKind.MatchCase) return { casePatterns: rd.nodeList(nodes), caseGuard: rd.nodeRef(nodes) as Node, caseBody: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.AwaitExpr) return { awaitArg: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.YieldExpr) return { yieldArg: rd.nodeRef(nodes) as Node, isDelegate: rd.flag() } as NodeData;
	if (kind == NodeKind.MoveExpr) return { moveArg: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.OutExpr) return { outArg: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.SizeofExpr) return { sizeofType: rd.text(), sizeofResolved: rd.typeRef(types) as Type } as NodeData;
	if (kind == NodeKind.HiddenStdConv || kind == NodeKind.HiddenSubConv) return { convExpr: rd.nodeRef(nodes) as Node, convType: rd.typeRef(types) as Type } as NodeData;
	if (kind == NodeKind.HiddenDeref || kind == NodeKind.HiddenAddr) return { expr: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.TypeAnnotation) return { annotationType: rd.text() } as NodeData;
	if (kind == NodeKind.ArrayPattern) return { patternElements: rd.nodeList(nodes), hasRestElement: rd.flag(), patternDefaults: rd.nodeList(nodes) } as NodeData;
	if (kind == NodeKind.ObjectPattern) return { patternProps: rd.nodeList(nodes), hasRestProp: rd.flag() } as NodeData;
	if (kind == NodeKind.ObjectPatternProp) return { propKey: rd.text(), propAlias: rd.nodeRef(nodes) as Node, propDefault: rd.nodeRef(nodes) } as NodeData;
	if (kind == NodeKind.DestructuringDecl) return { destrPattern: rd.nodeRef(nodes) as Node, destrInit: rd.nodeRef(nodes) as Node, destrIsConst: rd.flag(), destrType: rd.text() } as NodeData;
	if (kind == NodeKind.VariableDecl) return { declName: rd.text(), declType: rd.text(), initializer: rd.nodeRef(nodes) as Node, declKind: rd.dec() as DeclKind, nameLocation: rd.location() as SourceLocation } as NodeData;
	if (kind == NodeKind.IfStmt) return { condition: rd.nodeRef(nodes) as Node, consequent: rd.nodeRef(nodes) as Node, alternate: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.WhileStmt) return { whileCondition: rd.nodeRef(nodes) as Node, whileBody: rd.nodeRef(nodes) as Node, whileLabel: rd.text() } as NodeData;
	if (kind == NodeKind.ForStmt) return { forInit: rd.nodeRef(nodes) as Node, forCondition: rd.nodeRef(nodes) as Node, forUpdate: rd.nodeRef(nodes) as Node, forBody: rd.nodeRef(nodes) as Node, forLabel: "" } as NodeData;
	if (kind == NodeKind.ForOfStmt) return { forOfBinding: rd.text(), forOfIsConst: rd.flag(), forOfIterable: rd.nodeRef(nodes) as Node, forOfBody: rd.nodeRef(nodes) as Node, forOfPattern: rd.nodeRef(nodes) as Node, bindingLocation: rd.location() as SourceLocation, forOfLabel: "" } as NodeData;
	if (kind == NodeKind.ForInStmt) return { forInBinding: rd.text(), forInIsConst: rd.flag(), forInObject: rd.nodeRef(nodes) as Node, forInBody: rd.nodeRef(nodes) as Node, forInLabel: "" } as NodeData;
	if (kind == NodeKind.BlockStmt) return { statements: rd.nodeList(nodes) } as NodeData;
	if (kind == NodeKind.ExprStmt) return { expr: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.ReturnStmt) return { argument: rd.nodeRef(nodes) } as NodeData;
	if (kind == NodeKind.BreakStmt) return { breakLabel: rd.text() } as NodeData;
	if (kind == NodeKind.ContinueStmt) return { continueLabel: rd.text() } as NodeData;
	if (kind == NodeKind.FunctionDecl) return { fnName: rd.text(), params: rd.strList(), fnParamTypes: rd.strList(), fnBody: rd.nodeRef(nodes) as Node, fnFlags: rd.text(), fnReturnType: rd.text(), fnDefaults: rd.nodeList(nodes), nativeName: rd.text(), nameLocation: rd.location() as SourceLocation } as NodeData;
	if (kind == NodeKind.DoWhileStmt) return { doBody: rd.nodeRef(nodes) as Node, doCondition: rd.nodeRef(nodes) as Node, dwLabel: "", dwSwitchWrapper: false } as NodeData;
	if (kind == NodeKind.SwitchStmt) return { switchDisc: rd.nodeRef(nodes) as Node, switchCases: rd.nodeList(nodes), switchLowered: false } as NodeData;
	if (kind == NodeKind.SwitchCase) return { caseTests: rd.nodeList(nodes), caseStmts: rd.nodeList(nodes), isDefault: rd.flag() } as NodeData;
	if (kind == NodeKind.UnreachableStmt) return { unreachableMsg: rd.text() } as NodeData;
	if (kind == NodeKind.MatchStmt) return { matchStmtDisc: rd.nodeRef(nodes) as Node, matchStmtCases: rd.nodeList(nodes) } as NodeData;
	if (kind == NodeKind.ImportDecl) return { importNames: rd.strList(), importAliases: rd.strList(), importSource: rd.text(), nameLocations: rd.locList(), aliasLocations: rd.locList(), importTypeNames: rd.strList() } as NodeData;
	if (kind == NodeKind.ExportDecl) return { exportedDecl: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.TypeAliasDecl) return { aliasName: rd.text(), aliasType: rd.text(), aliasIsDistinct: rd.flag(), aliasGenericParams: rd.text(), discriminantName: rd.text(), discriminantType: rd.text(), variantKeys: rd.strList(), variantTypes: rd.strList(), nameLocation: rd.location() as SourceLocation } as NodeData;
	if (kind == NodeKind.EnumDecl) return { enumName: rd.text(), enumMembers: rd.strList(), enumValues: rd.floatList(), nameLocation: rd.location() as SourceLocation, memberLocations: rd.locList(), enumInits: rd.nodeList(nodes) } as NodeData;
	if (kind == NodeKind.InterfaceDecl || kind == NodeKind.StructDecl) return { interfaceName: rd.text(), interfaceFields: rd.strList(), interfaceFieldTypes: rd.strList(), interfaceExtends: rd.strList(), nameLocation: rd.location() as SourceLocation, interfaceFieldVisibility: rd.strList(), interfaceFieldDecorators: rd.nodeRows(nodes), interfaceOptionalFields: rd.strList(), nativeName: rd.text() } as NodeData;
	if (kind == NodeKind.ClassDecl) return { className: rd.text(), classDisplayName: rd.text(), classExtends: rd.text(), classBody: rd.nodeList(nodes), nameLocation: rd.location() as SourceLocation, classImplements: rd.strList() } as NodeData;
	if (kind == NodeKind.PropertyDecl) return { propName: rd.text(), propType: rd.text(), propIsStatic: rd.flag(), propIsReadonly: rd.flag(), propVisibility: rd.text(), propInitializer: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.MethodDecl) return { methodName: rd.text(), methodParams: rd.strList(), methodParamTypes: rd.strList(), methodBody: rd.nodeRef(nodes) as Node, methodIsStatic: rd.flag(), methodFlags: rd.text(), methodVisibility: rd.text(), methodReturnType: rd.text(), methodDefaults: rd.nodeList(nodes), nativeName: rd.text(), nameLocation: rd.location() as SourceLocation } as NodeData;
	if (kind == NodeKind.ConstructorDecl) return { ctorParams: rd.strList(), ctorParamTypes: rd.strList(), ctorBody: rd.nodeRef(nodes) as Node, ctorDefaults: rd.nodeList(nodes), ctorVisibility: rd.text(), ctorParamProps: rd.nodeList(nodes), ctorFlags: rd.text() } as NodeData;
	if (kind == NodeKind.ThrowStmt) return { throwArg: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.TryCatchStmt) return { tryBody: rd.nodeRef(nodes) as Node, catchName: rd.text(), catchBody: rd.nodeRef(nodes) as Node, finallyBody: rd.nodeRef(nodes) as Node, catchBindingLocation: rd.location() as SourceLocation, hasCatchClause: rd.flag() } as NodeData;
	if (kind == NodeKind.MacroInvocation) return { macroName: rd.text(), macroArgs: rd.nodeList(nodes), macroHasParens: rd.last == 9 && rd.flag() } as NodeData;
	if (kind == NodeKind.DecoratedDecl) return { decorators: rd.nodeList(nodes), decoratedNode: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.DeferStmt) return { deferExpr: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.TestDecl) return { testName: rd.text(), testBody: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.AssertStmt) return { assertExpr: rd.nodeRef(nodes) as Node, assertSource: rd.text(), assertMessage: rd.text(), assertMessageExpr: rd.nodeRef(nodes) } as NodeData;
	if (kind == NodeKind.ExternDecl) return { externKind: rd.dec() as ExternKind, externName: rd.text(), nativeName: rd.text(), externType: rd.text() } as NodeData;
	if (kind == NodeKind.MacroDecl) return { macroDeclName: rd.text(), macroDeclParams: rd.strList(), macroDeclParamTypes: rd.strList(), macroDeclReturnType: rd.text(), macroDeclBody: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.QuoteExpr) return { quoteBody: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.ComptimeBlock) return { comptimeBody: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.TypeGeneric) return { typExprBase: rd.nodeRef(nodes) as Node, typExprArgs: rd.nodeList(nodes) } as NodeData;
	if (kind == NodeKind.TypeArray) return { typExprElement: rd.nodeRef(nodes) as Node, typExprSize: rd.str().parseFloat() } as NodeData;
	if (kind == NodeKind.TypeUnion) return { typExprMembers: rd.nodeList(nodes), discFieldName: rd.text(), variantKeys: rd.strList(), discKind: rd.text() } as NodeData;
	if (kind == NodeKind.TypeIntersection) return { typExprMembers: rd.nodeList(nodes) } as NodeData;
	if (kind == NodeKind.TypeFunction) return { typExprParams: rd.nodeList(nodes), typExprReturn: rd.nodeRef(nodes) as Node, typExprParamNames: rd.strList() } as NodeData;
	if (kind == NodeKind.TypeObject) return { typExprFieldNames: rd.strList(), typExprFieldTypes: rd.nodeList(nodes), typExprIndexKey: rd.nodeRef(nodes) as Node, typExprIndexValue: rd.nodeRef(nodes) as Node, typExprFieldDecorators: rd.nodeRows(nodes), typExprTypeName: rd.text(), typExprOptionalFields: rd.strList() } as NodeData;
	if (kind == NodeKind.Program) return { programStmts: rd.nodeList(nodes) } as NodeData;
	if (kind == NodeKind.ActorDecl) return { actorName: rd.text(), actorBody: rd.nodeList(nodes), nameLocation: rd.location() as SourceLocation } as NodeData;
	if (kind == NodeKind.SpliceMany) return { spliceNodes: rd.nodeList(nodes) } as NodeData;
	if (kind == NodeKind.JSXElement) return { jsxTag: rd.text(), jsxAttrs: rd.nodeList(nodes), jsxChildren: rd.nodeList(nodes), jsxSelfClosing: rd.flag() } as NodeData;
	if (kind == NodeKind.JSXFragment) return { jsxFragChildren: rd.nodeList(nodes) } as NodeData;
	if (kind == NodeKind.JSXText) return { jsxText: rd.text() } as NodeData;
	if (kind == NodeKind.JSXExpressionContainer) return { jsxExpr: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.JSXAttribute) return { jsxAttrName: rd.text(), jsxAttrValue: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.JSXSpreadAttribute) return { jsxSpreadArg: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.ComputedProperty) return { computedKey: rd.nodeRef(nodes) as Node, computedValue: rd.nodeRef(nodes) as Node } as NodeData;
	return { nullPlaceholder: true } as NodeData;
}

function packedBuiltinKind(name: string): BuiltinKind {
	if (name == "") return BuiltinKind.None;
	const kind = builtinKindNamed(name);
	if (kind == null) throw new Error(`internal: the prelude pack names builtin '${name}', which this compiler does not know`);
	return kind;
}

export enum FieldRoleKind {
	Encoded,
	Derived,
	WrittenAsNull,
	MustBeNull,
}

export class FieldRole {
	constructor(public kind: FieldRoleKind, public why: string) {}
}

function encoded(column: string): FieldRole {
	return new FieldRole(FieldRoleKind.Encoded, column);
}

export const SYMBOL_FIELD_ROLES: { [K in keyof Symbol]-?: FieldRole } = {
	name: encoded("S name"),
	nameId: new FieldRole(FieldRoleKind.Derived, "re-interned from name in the loading context's ident cache by the loader"),
	symbolKind: encoded("S kind"),
	symbolType: encoded("S typeIdx"),
	state: encoded("S state"),
	location: encoded("S locLine locCol locEndLine locEndCol"),
	declNode: encoded("S declIdx"),
	overloads: encoded("S overloadsCsv"),
	nativeName: encoded("S nativeName"),
	exportName: encoded("S exportName"),
	builtinKind: encoded("S builtinKind, by name"),
	symFlags: encoded("S flags"),
	defaultParams: encoded("S dpCsv"),
	modulePath: encoded("S modulePath"),
	headerPath: encoded("S headerPath"),
	jsModulePath: encoded("S jsModulePath"),
	overloadIdx: encoded("S overloadIdx"),
	disamb: encoded("S disamb"),
	mutatedParams: encoded("S mutatedParams"),
	staticFields: encoded("S staticCsv"),
	fieldDecoratorNames: encoded("S fieldDecoratorNamesCsv"),
	fieldDecorators: encoded("S fieldDecoratorRows"),
	metaKeys: encoded("S metaKeysCsv"),
	metaValues: encoded("S metaValuesCsv"),
	nonisolatedFields: encoded("S nonisolatedCsv"),
	duVariantSlot: encoded("S duVariantSlot"),
	itemModule: encoded("S itemModule"),
	item: encoded("S item"),
	instantiatedFrom: encoded("S originIdx"),
	instanceArgs: encoded("S instArgsCsv"),
	instanceParams: encoded("S instParamsCsv"),
	ctorRoutine: encoded("S ctorRoutineIdx"),
	ctorOwner: encoded("S ctorOwnerIdx"),
	borrowedFrom: encoded("S borrowedFromIdx"),
	subclasses: encoded("S subclassesCsv"),
	staticOwner: encoded("S ownerIdx"),
	typeParamOwner: encoded("S paramOwnerIdx"),
	typeParams: encoded("S typeParamsCsv"),
};

export const TYPE_FIELD_ROLES: { [K in keyof Type]-?: FieldRole } = {
	kind: encoded("T kind"),
	typeName: encoded("T typeName"),
	typeNames: encoded("T typeNamesCsv"),
	typeChildren: encoded("T childrenCsv"),
	typeReturn: encoded("T ret"),
	typeExtra: encoded("T extra"),
	typeParamDefault: encoded("T typeParamDefault"),
	typeFlags: encoded("T flags"),
	typeValue: encoded("T value"),
	callConv: encoded("T callConv"),
	attachedOps: encoded("T opsCsv"),
	sym: encoded("T symIdx"),
	typeInst: encoded("T typeInst"),
	readonlyView: encoded("T readonlyView"),
	mutableView: encoded("T mutableView"),
	ownedType: encoded("T ownedType"),
	plainType: encoded("T plainType"),
	optionalFields: encoded("T optionalFieldsCsv"),
};

export const NODE_FIELD_ROLES: { [K in keyof Node]-?: FieldRole } = {
	kind: encoded("N kind"),
	location: encoded("N l c el ec"),
	data: encoded("N payload: the kind's fieldspec nodeFields columns, read back by buildNodeData"),
	nodeType: encoded("N typeIdx"),
	resolvedSym: encoded("N symIdx"),
	flags: encoded("N flags"),
	variantSlot: encoded("N variantSlot"),
	typeExpr: encoded("N typeExprIdx"),
	typeExprs: encoded("N typeExprsCsv"),
	genericDefaults: encoded("N genericDefaultsCsv"),
	baseExprs: encoded("N baseExprsCsv"),
	paramLocations: encoded("N paramLocsCsv"),
	paramSyms: encoded("N paramSymsCsv"),
	typeArg: encoded("N typeArg"),
	flowNode: new FieldRole(FieldRoleKind.WrittenAsNull, "narrowing graph of its own module's check; a clone of the tree is bound again by bindFunctionFlow"),
	nodeTypeAst: encoded("N typeAstIdx"),
	inlineFrame: new FieldRole(FieldRoleKind.MustBeNull, "set only by transform-time inlining, after the check whose trees the codec writes"),
};

// ===== Object rows: writer =====
//
// Line format (tab-separated; \1.. prefixes keep the reader dumb):
//   T idx kind flags value callConv typeName typeNamesCsv childrenCsv ret extra symIdx optionalFieldsCsv
//     opsCsv readonlyView mutableView typeInst typeParamDefault ownedType plainType wellKnown
//   N idx kind flags l c el ec typeIdx symIdx typeExprIdx typeExprsCsv paramLocsCsv typeArg variantSlot paramSymsCsv baseExprsCsv genericDefaultsCsv typeAstIdx <payload...>
//   S idx kind state flags overloadIdx mutatedParams duVariantSlot
//     locLine locCol locEndLine locEndCol inScope
//     name modulePath nativeName builtinKind headerPath jsModulePath
//     typeIdx overloadsCsv staticCsv declIdx dpCsv disamb exportName
//     ownerIdx typeParamsCsv originIdx paramOwnerIdx instArgsCsv instParamsCsv
//     fieldDecoratorNamesCsv fieldDecoratorRows metaKeysCsv metaValuesCsv nonisolatedCsv
//     itemModule item ctorRoutineIdx ctorOwnerIdx borrowedFromIdx subclassesCsv
//
// A *Csv column, and a payload list, is "-" for null, otherwise `<count>:`
// and the items joined by ',' (an escaped string holds no raw ','), so null,
// [], [""] and ["", "a,b"] read back apart. A location is line/column/
// endLine/endColumn joined by '/', or "-" for null. A nested list
// (fieldDecoratorRows) is `<count>:` and its rows, each a list, joined by ';'.
// A list whose type holds no null is refused at write when it is null.

export class RowWriter {
	syms: Symbol[] = [];
	symIdx: HashMap<Symbol, int32> = new HashMap<Symbol, int32>();
	types: Type[] = [];
	typeIdx: HashMap<Type, int32> = new HashMap<Type, int32>();
	nodes: Node[] = [];
	nodeIdx: HashMap<Node, int32> = new HashMap<Node, int32>();
	roots: HashSet<Symbol> = new HashSet<Symbol>();
	symCursor: int32 = 0;
	typeCursor: int32 = 0;
	nodeCursor: int32 = 0;
}

// Index at enqueue time so every later index read is guaranteed present
// (no Maybe at write sites).
export function enqSym(this w: RowWriter, s: Symbol | null, root: boolean): void {
	if (s == null || w.symIdx.has(s)) return;
	w.symIdx.set(s, w.syms.length as int32);
	w.syms.push(s);
	if (root) w.roots.add(s);
}

export function enqType(this w: RowWriter, t: Type | null): void {
	if (t == null || w.typeIdx.has(t)) return;
	w.typeIdx.set(t, w.types.length as int32);
	w.types.push(t);
}

export function enqNode(this w: RowWriter, n: Node | null): void {
	if (n == null || w.nodeIdx.has(n)) return;
	w.nodeIdx.set(n, w.nodes.length as int32);
	w.nodes.push(n);
}

// Maybe-unwrapping helpers: a ternary `cond ? map.get(k) : -1` leaks the
// Maybe struct to C; a function with an if-block narrows properly.
export function idxSym(this w: RowWriter, s: Symbol | null): int32 {
	if (s == null || !w.symIdx.has(s)) return -1;
	const v = w.symIdx.get(s);
	return v == null ? -1 : v;
}

export function idxType(this w: RowWriter, t: Type | null): int32 {
	if (t == null || !w.typeIdx.has(t)) return -1;
	const v = w.typeIdx.get(t);
	return v == null ? -1 : v;
}

export function idxNode(this w: RowWriter, n: Node | null): int32 {
	if (n == null || !w.nodeIdx.has(n)) return -1;
	const v = w.nodeIdx.get(n);
	return v == null ? -1 : v;
}

export function idxs(this w: RowWriter, arr: Node[] | null): string {
	if (arr == null) return "-";
	const ids: int32[] = [];
	for (const n of arr) ids.push(w.idxNode(n));
	return intListText(ids);
}

function typeIdxs(this w: RowWriter, ts: Type[] | null): string {
	if (ts == null) return "-";
	const ids: int32[] = [];
	for (const t of ts) ids.push(w.idxType(t));
	return intListText(ids);
}

function symIdxs(this w: RowWriter, ss: Symbol[] | null): string {
	if (ss == null) return "-";
	const ids: int32[] = [];
	for (const s of ss) ids.push(w.idxSym(s));
	return intListText(ids);
}

function transformOnlyField(n: Node): string {
	const kind = n.kind;
	if (kind == NodeKind.ForStmt && (n.data as ForStmtData).forLabel != "") return "forLabel";
	if (kind == NodeKind.ForOfStmt && (n.data as ForOfStmtData).forOfLabel != "") return "forOfLabel";
	if (kind == NodeKind.ForInStmt && (n.data as ForInStmtData).forInLabel != "") return "forInLabel";
	if (kind == NodeKind.DoWhileStmt) {
		const d = n.data as DoWhileStmtData;
		if (d.dwLabel != "") return "dwLabel";
		if (d.dwSwitchWrapper) return "dwSwitchWrapper";
	}
	if (kind == NodeKind.SwitchStmt && (n.data as SwitchStmtData).switchLowered) return "switchLowered";
	return "";
}

export function closeOver(this w: RowWriter): void {
	// Enqueue every Node child of a node, per NodeData variant. Field order
	// mirrors the reader's buildNodeData — keep the two switches in sync.
	// Field-sink for the walk phase: only refs matter (enqNode assigns row
	// indexes; call order inside nodeFields defines the N-row ordering). All
	// value fields are ignored.
	const walkSink: FieldSink = {
		node: (name: string, x: Node | null): void => { w.enqNode(x); },
		nodes: (name: string, a: Node[] | null): void => { if (a != null) { for (const c of a) w.enqNode(c); } },
		nodesNested: (name: string, a: Node[][] | null): void => { if (a != null) { for (const row of a) { if (row != null) { for (const c of row) w.enqNode(c); } } } },
		typ: (name: string, t: Type | null): void => { w.enqType(t); },
		str: (name: string, s: string): void => {},
		strArr: (name: string, a: string[] | null): void => {},
		integer: (name: string, v: int64): void => {},
		float: (name: string, v: float64): void => {},
		bool: (name: string, b: boolean): void => {},
		loc: (name: string, l: SourceLocation | null): void => {},
		locs: (name: string, l: SourceLocation[] | null): void => {},
		floats: (name: string, a: number[] | null): void => {},
	};
	while (w.symCursor < w.syms.length || w.typeCursor < w.types.length || w.nodeCursor < w.nodes.length) {
		if (w.symCursor < w.syms.length) {
			const s = w.syms[w.symCursor];
			w.symCursor += 1;
			w.enqType(s.symbolType);
			for (const tp of s.typeParams) w.enqType(tp);
			for (const t of s.instanceArgs ?? []) w.enqType(t);
			for (const t of s.instanceParams ?? []) w.enqType(t);
			for (const t of s.subclasses ?? []) w.enqType(t);
			if (s.overloads != null) {
				for (const ov of s.overloads) w.enqSym(ov, false);
			}
			if (s.staticOwner != null) w.enqSym(s.staticOwner, false);
			if (s.typeParamOwner != null) w.enqSym(s.typeParamOwner, false);
			if (s.instantiatedFrom != null) w.enqSym(s.instantiatedFrom, false);
			if (s.staticFields != null) {
				for (const sf of s.staticFields) w.enqSym(sf, false);
			}
			w.enqNode(s.declNode);
			for (const dp of s.defaultParams) w.enqNode(dp);
			for (const row of s.fieldDecorators) {
				for (const d of row) w.enqNode(d);
			}
			for (const v of s.metaValues) w.enqNode(v);
			w.enqSym(s.ctorRoutine, false);
			w.enqSym(s.ctorOwner, false);
			w.enqSym(s.borrowedFrom, false);
			continue;
		}
		if (w.nodeCursor < w.nodes.length) {
			const n = w.nodes[w.nodeCursor];
			w.nodeCursor += 1;
			w.enqType(n.nodeType);
			w.enqSym(n.resolvedSym, false);
			if (n.paramSyms != null) {
				for (const ps of n.paramSyms) w.enqSym(ps, false);
			}
			w.enqNode(n.typeExpr);
			if (n.typeExprs != null) {
				for (const te of n.typeExprs) w.enqNode(te);
			}
			if (n.genericDefaults != null) {
				for (const value of n.genericDefaults) w.enqNode(value);
			}
			if (n.baseExprs != null) {
				for (const be of n.baseExprs) w.enqNode(be);
			}
			w.enqNode(n.nodeTypeAst);
			nodeFields(n, walkSink);
			continue;
		}
		const t = w.types[w.typeCursor];
		w.typeCursor += 1;
		if (t.typeChildren != null) {
			for (const c of t.typeChildren) w.enqType(c);
		}
		w.enqType(t.typeReturn);
		w.enqType(t.typeExtra);
		w.enqType(t.typeParamDefault);
		w.enqType(t.readonlyView);
		w.enqType(t.mutableView);
		w.enqType(t.typeInst);
		w.enqType(t.ownedType);
		w.enqType(t.plainType);
		w.enqSym(t.sym, false);
		for (const op of t.attachedOps) w.enqSym(op, false);
	}
}

export function emitObjectRows(this w: RowWriter, lines: string[]): void {
	const wellKnown = new HashMap<Type, int32>();
	const known = wellKnownTypes();
	for (let k = 0; k < known.length; k += 1) wellKnown.set(known[k], k as int32);
	for (let i = 0; i < w.types.length; i += 1) {
		const t = w.types[i];
		const nullList = t.typeNames == null ? "typeNames" : t.typeChildren == null ? "typeChildren" : t.attachedOps == null ? "attachedOps" : "";
		if (nullList != "") throw nullListError(`type ${i} (${t.typeName})`, nullList);
		const ops: int32[] = [];
		for (const o of t.attachedOps) ops.push(w.idxSym(o));
		lines.push(`T\t${i}\t${t.kind as int32}\t${t.typeFlags as uint32}\t${t.typeValue}\t${t.callConv as int32}\t${escapeP(t.typeName)}\t${strListText(t.typeNames)}\t${w.typeIdxs(t.typeChildren)}\t${w.idxType(t.typeReturn)}\t${w.idxType(t.typeExtra)}\t${w.idxSym(t.sym)}\t${strListText(t.optionalFields)}\t${intListText(ops)}\t${w.idxType(t.readonlyView)}\t${w.idxType(t.mutableView)}\t${w.idxType(t.typeInst)}\t${w.idxType(t.typeParamDefault)}\t${w.idxType(t.ownedType)}\t${w.idxType(t.plainType)}\t${wellKnownIndex(wellKnown, t)}`);
	}

	_wnodeIdx = w.nodeIdx;
	_wtypeIdx = w.typeIdx;
	for (let i = 0; i < w.nodes.length; i += 1) {
		const n = w.nodes[i];
		if (n.inlineFrame != null) throw new Error(`internal: ${nodeOwner(i, n)} carries an inlineFrame, which only transform-time inlining sets; the object rows hold checked trees`);
		const unwritten = transformOnlyField(n);
		if (unwritten != "") throw new Error(`internal: ${nodeOwner(i, n)} sets ${unwritten}, which only a transform writes and the object rows do not carry`);
		const loc = n.location;
		let defaults: int32[] | null = null;
		if (n.genericDefaults != null) {
			const ids: int32[] = [];
			for (const value of n.genericDefaults) ids.push(w.idxNode(value));
			defaults = ids;
		}
		lines.push(`N\t${i}\t${n.kind as int32}\t${n.flags as uint64}\t${loc.line}\t${loc.column}\t${loc.endLine}\t${loc.endColumn}\t${w.idxType(n.nodeType)}\t${w.idxSym(n.resolvedSym)}\t${w.idxNode(n.typeExpr)}\t${w.idxs(n.typeExprs)}\t${locListText(n.paramLocations)}\t${escapeP(n.typeArg)}\t${n.variantSlot}\t${w.symIdxs(n.paramSyms)}\t${w.idxs(n.baseExprs)}\t${intListText(defaults)}\t${w.idxNode(n.nodeTypeAst)}\t${emitNodePayloadViaSink(i, n)}`);
	}

	for (let i = 0; i < w.syms.length; i += 1) {
		const s = w.syms[i];
		const nullList = symbolNullList(s);
		if (nullList != "") throw nullListError(`symbol ${i} (${s.name})`, nullList);
		const loc = s.location;
		lines.push(`S\t${i}\t${s.symbolKind as int32}\t${s.state as int32}\t${s.symFlags as uint64}\t${s.overloadIdx}\t${s.mutatedParams}\t${s.duVariantSlot}\t${loc !== null ? loc.line : 0}\t${loc !== null ? loc.column : 0}\t${loc !== null ? loc.endLine : 0}\t${loc !== null ? loc.endColumn : 0}\t${w.roots.has(s) ? 1 : 0}\t${escapeP(s.name)}\t${escapeP(s.modulePath)}\t${escapeP(s.nativeName)}\t${escapeP(builtinKindName(s.builtinKind))}\t${escapeP(s.headerPath)}\t${escapeP(s.jsModulePath)}\t${w.idxType(s.symbolType)}\t${w.symIdxs(s.overloads)}\t${w.symIdxs(s.staticFields)}\t${w.idxNode(s.declNode)}\t${w.idxs(strongOrNull(s.defaultParams))}\t${s.disamb}\t${escapeP(s.exportName)}\t${w.idxSym(s.staticOwner)}\t${w.typeIdxs(s.typeParams)}\t${w.idxSym(s.instantiatedFrom)}\t${w.idxSym(s.typeParamOwner)}\t${w.typeIdxs(s.instanceArgs)}\t${w.typeIdxs(s.instanceParams)}\t${strListText(s.fieldDecoratorNames)}\t${nestedIdxsP(strongRows(s.fieldDecorators))}\t${strListText(s.metaKeys)}\t${w.idxs(strongOrNull(s.metaValues))}\t${strListText(s.nonisolatedFields)}\t${s.itemModule}\t${s.item}\t${w.idxSym(s.ctorRoutine)}\t${w.idxSym(s.ctorOwner)}\t${w.idxSym(s.borrowedFrom)}\t${w.typeIdxs(s.subclasses)}`);
	}
}

function symbolNullList(s: Symbol): string {
	if (s.overloads == null) return "overloads";
	if (s.staticFields == null) return "staticFields";
	if (s.defaultParams == null) return "defaultParams";
	if (s.typeParams == null) return "typeParams";
	if (s.fieldDecoratorNames == null) return "fieldDecoratorNames";
	const row = nullRowPath(s.fieldDecorators);
	if (row != null) return `fieldDecorators${row}`;
	if (s.metaKeys == null) return "metaKeys";
	if (s.metaValues == null) return "metaValues";
	if (s.nonisolatedFields == null) return "nonisolatedFields";
	return "";
}

function wellKnownIndex(known: HashMap<Type, int32>, t: Type): int32 {
	if (!known.has(t)) return -1;
	const v = known.get(t);
	return v == null ? -1 : v;
}

// ===== Object rows: reader =====

export class RowReader {
	types: Type[] = [];
	syms: Symbol[] = [];
	nodes: Node[] = [];
	rootFlags: int32[] = [];
	typeChildrenIdx: int32[][] = [];
	typeReturnIdx: int32[] = [];
	typeExtraIdx: int32[] = [];
	typeSymIdx: int32[] = [];
	typeOpsIdx: int32[][] = [];
	typeViewIdx: int32[] = [];
	typeMutableIdx: int32[] = [];
	typeInstIdx: int32[] = [];
	typeDefaultIdx: int32[] = [];
	typeOwnedIdx: int32[] = [];
	typePlainIdx: int32[] = [];
	typeWellKnown: int32[] = [];
	wellKnown: Type[] = wellKnownTypes();
	symTypeIdx: int32[] = [];
	symOverloadIdx: int32[][] = [];
	symStaticIdx: int32[][] = [];
	symDeclIdx: int32[] = [];
	symOwnerIdx: int32[] = [];
	symTypeParamsIdx: int32[][] = [];
	symOriginIdx: int32[] = [];
	symParamOwnerIdx: int32[] = [];
	symInstanceArgsIdx: (int32[] | null)[] = [];
	symInstanceParamsIdx: (int32[] | null)[] = [];
	symDpIdx: int32[][] = [];
	symFieldDecoratorsIdx: int32[][][] = [];
	symMetaValuesIdx: int32[][] = [];
	symCtorRoutineIdx: int32[] = [];
	symCtorOwnerIdx: int32[] = [];
	symBorrowedFromIdx: int32[] = [];
	symSubclassesIdx: (int32[] | null)[] = [];
	nodeTypeRef: int32[] = [];
	nodeSymRef: int32[] = [];
	nodeTeRef: int32[] = [];
	nodeTesIdx: (int32[] | null)[] = [];
	nodeBesIdx: (int32[] | null)[] = [];
	nodeDefaultsIdx: (int32[] | null)[] = [];
	nodePssIdx: (int32[] | null)[] = [];
	nodeTypeAstRef: int32[] = [];
	nodePayloadPos: int32[] = [];
	placeholder: NodeData = { nullPlaceholder: true } as NodeData;
}

export function readObjectRow(this a: RowReader, tag: int32, rd: PackReader): boolean {
	if (tag == 84) {
		rd.skip();
		const t = emptyType();
		t.kind = rd.int() as int32 as TypeKind;
		t.typeFlags = rd.int() as uint32 as BitSet<TypeFlag>;
		t.typeValue = rd.int() as int32;
		t.callConv = rd.int() as int32 as CallingConvention;
		t.typeName = unescapeP(rd.str());
		t.typeNames = rd.strList();
		a.typeChildrenIdx.push(rd.intList());
		a.typeReturnIdx.push(rd.int() as int32);
		a.typeExtraIdx.push(rd.int() as int32);
		a.typeSymIdx.push(rd.int() as int32);
		t.optionalFields = rd.nullableStrs();
		a.typeOpsIdx.push(rd.intList());
		a.typeViewIdx.push(rd.int() as int32);
		a.typeMutableIdx.push(rd.int() as int32);
		a.typeInstIdx.push(rd.int() as int32);
		a.typeDefaultIdx.push(rd.int() as int32);
		a.typeOwnedIdx.push(rd.int() as int32);
		a.typePlainIdx.push(rd.int() as int32);
		const wk = rd.int() as int32;
		a.typeWellKnown.push(wk);
		if (wk == -1) a.types.push(t);
		else if (wk >= 0 && wk < a.wellKnown.length && a.wellKnown[wk].kind == t.kind) a.types.push(a.wellKnown[wk]);
		else {
			rd.bad = true;
			a.types.push(t);
		}
		rd.endRow();
		return true;
	}
	if (tag == 78) {
		rd.skip();
		const kind = rd.int() as int32 as NodeKind;
		const flags = rd.int() as uint64 as BitSet<NodeFlag>;
		const line = rd.int() as int32;
		const column = rd.int() as int32;
		const endLine = rd.int() as int32;
		const endColumn = rd.int() as int32;
		const n = createNodeAt(kind, a.placeholder, makeLocRange(line, column, endLine, endColumn));
		n.flags = flags;
		a.nodeTypeRef.push(rd.int() as int32);
		a.nodeSymRef.push(rd.int() as int32);
		a.nodeTeRef.push(rd.int() as int32);
		a.nodeTesIdx.push(rd.nullableInts());
		n.paramLocations = rd.nullableLocs();
		n.typeArg = unescapeP(rd.str());
		n.variantSlot = rd.int() as int32;
		a.nodePssIdx.push(rd.nullableInts());
		a.nodeBesIdx.push(rd.nullableInts());
		a.nodeDefaultsIdx.push(rd.nullableInts());
		a.nodeTypeAstRef.push(rd.int() as int32);
		a.nodePayloadPos.push(rd.last == 9 ? rd.pos : -1);
		rd.endRow();
		a.nodes.push(n);
		return true;
	}
	if (tag == 83) {
		rd.skip();
		const kind = rd.int() as int32 as SymbolKind;
		const state = rd.int() as int32 as SymbolState;
		const symFlags = rd.int() as uint64 as BitSet<SymbolFlag>;
		const overloadIdx = rd.int() as int32;
		const mutatedParams = rd.int() as int32;
		const duVariantSlot = rd.int() as int32;
		const l = rd.int() as int32;
		const c = rd.int() as int32;
		const el = rd.int() as int32;
		const ec = rd.int() as int32;
		a.rootFlags.push(rd.int() == 1 ? 1 : 0);
		const s = makeSymbolState(unescapeP(rd.str()), kind, null, false, SymbolState.Hollow);
		s.state = state;
		s.symFlags = symFlags;
		s.overloadIdx = overloadIdx;
		s.mutatedParams = mutatedParams;
		s.duVariantSlot = duVariantSlot;
		s.location = makeLocRange(l, c, el, ec);
		s.modulePath = unescapeP(rd.str());
		s.nativeName = unescapeP(rd.str());
		s.builtinKind = packedBuiltinKind(unescapeP(rd.str()));
		s.headerPath = unescapeP(rd.str());
		s.jsModulePath = unescapeP(rd.str());
		a.symTypeIdx.push(rd.int() as int32);
		a.symOverloadIdx.push(rd.intList());
		a.symStaticIdx.push(rd.intList());
		a.symDeclIdx.push(rd.int() as int32);
		a.symDpIdx.push(rd.intList());
		if (rd.last == 9) s.disamb = rd.int() as int32;
		if (rd.last == 9) s.exportName = unescapeP(rd.str());
		a.symOwnerIdx.push(rd.last == 9 ? rd.int() as int32 : -1);
		a.symTypeParamsIdx.push(rd.intList());
		a.symOriginIdx.push(rd.last == 9 ? rd.int() as int32 : -1);
		a.symParamOwnerIdx.push(rd.last == 9 ? rd.int() as int32 : -1);
		a.symInstanceArgsIdx.push(rd.nullableInts());
		a.symInstanceParamsIdx.push(rd.nullableInts());
		s.fieldDecoratorNames = rd.strList();
		a.symFieldDecoratorsIdx.push(rd.idRows());
		s.metaKeys = rd.strList();
		a.symMetaValuesIdx.push(rd.intList());
		s.nonisolatedFields = rd.strList();
		s.itemModule = rd.int() as int32;
		s.item = rd.int() as int32;
		a.symCtorRoutineIdx.push(rd.int() as int32);
		a.symCtorOwnerIdx.push(rd.int() as int32);
		a.symBorrowedFromIdx.push(rd.int() as int32);
		a.symSubclassesIdx.push(rd.nullableInts());
		a.syms.push(s);
		rd.endRow();
		return true;
	}
	return false;
}

function badRef(k: int32, count: int32): boolean {
	return k < -1 || k >= count;
}

export function linkTypesAndSymbols(this a: RowReader): boolean {
	const types = a.types;
	const syms = a.syms;
	const nodes = a.nodes;
	for (let i = 0; i < types.length; i += 1) {
		if (a.typeWellKnown[i] >= 0) continue;
		const t = types[i];
		if (!refsFit(a.typeChildrenIdx[i], types.length, false) || !refsFit(a.typeOpsIdx[i], syms.length, true)) return false;
		t.typeChildren = typesAt(a.typeChildrenIdx[i], types);
		t.typeReturn = a.typeReturnIdx[i] >= 0 && a.typeReturnIdx[i] < types.length ? types[a.typeReturnIdx[i]] : null as unknown as Type;
		t.typeExtra = a.typeExtraIdx[i] >= 0 && a.typeExtraIdx[i] < types.length ? types[a.typeExtraIdx[i]] : null as unknown as Type;
		t.sym = a.typeSymIdx[i] >= 0 && a.typeSymIdx[i] < syms.length ? syms[a.typeSymIdx[i]] : null as unknown as Symbol;
		t.readonlyView = a.typeViewIdx[i] >= 0 && a.typeViewIdx[i] < types.length ? types[a.typeViewIdx[i]] : null;
		t.mutableView = a.typeMutableIdx[i] >= 0 && a.typeMutableIdx[i] < types.length ? types[a.typeMutableIdx[i]] : null;
		t.typeParamDefault = a.typeDefaultIdx[i] >= 0 && a.typeDefaultIdx[i] < types.length ? types[a.typeDefaultIdx[i]] : null;
		t.typeInst = a.typeInstIdx[i] >= 0 && a.typeInstIdx[i] < types.length ? types[a.typeInstIdx[i]] : null;
		if (badRef(a.typeOwnedIdx[i], types.length) || badRef(a.typePlainIdx[i], types.length)) return false;
		t.ownedType = a.typeOwnedIdx[i] >= 0 ? types[a.typeOwnedIdx[i]] : null;
		t.plainType = a.typePlainIdx[i] >= 0 ? types[a.typePlainIdx[i]] : null;
		for (const k of a.typeOpsIdx[i]) t.attachedOps.push(k >= 0 ? syms[k] : null);
	}

	for (let i = 0; i < syms.length; i += 1) {
		const s = syms[i];
		s.symbolType = a.symTypeIdx[i] >= 0 && a.symTypeIdx[i] < types.length ? types[a.symTypeIdx[i]] : null as unknown as Type;
		const args = a.symInstanceArgsIdx[i];
		const params = a.symInstanceParamsIdx[i];
		const subs = a.symSubclassesIdx[i];
		if (!refsFit(a.symOverloadIdx[i], syms.length, false) || !refsFit(a.symStaticIdx[i], syms.length, false)
			|| !refsFit(a.symTypeParamsIdx[i], types.length, false) || !refsFit(args, types.length, false)
			|| !refsFit(params, types.length, false) || !refsFit(subs, types.length, false) || !refsFit(a.symDpIdx[i], nodes.length, true)
			|| !refsFit(a.symMetaValuesIdx[i], nodes.length, true)) return false;
		for (const row of a.symFieldDecoratorsIdx[i]) {
			if (!refsFit(row, nodes.length, true)) return false;
		}
		s.overloads = symsAt(a.symOverloadIdx[i], syms);
		s.staticFields = symsAt(a.symStaticIdx[i], syms);
		s.typeParams = typesAt(a.symTypeParamsIdx[i], types);
		s.instanceArgs = args == null ? null : typesAt(args, types);
		s.instanceParams = params == null ? null : typesAt(params, types);
		s.subclasses = subs == null ? null : typesAt(subs, types);
		s.staticOwner = a.symOwnerIdx[i] >= 0 && a.symOwnerIdx[i] < syms.length ? syms[a.symOwnerIdx[i]] : null;
		s.instantiatedFrom = a.symOriginIdx[i] >= 0 && a.symOriginIdx[i] < syms.length ? syms[a.symOriginIdx[i]] : null;
		s.typeParamOwner = a.symParamOwnerIdx[i] >= 0 && a.symParamOwnerIdx[i] < syms.length ? syms[a.symParamOwnerIdx[i]] : null;
		s.declNode = a.symDeclIdx[i] >= 0 && a.symDeclIdx[i] < nodes.length ? nodes[a.symDeclIdx[i]] : null as unknown as Node;
		s.defaultParams = backEdges(nodesAt(a.symDpIdx[i], nodes));
		const decorators: Unowned<Node>[][] = [];
		for (const row of a.symFieldDecoratorsIdx[i]) decorators.push(backEdges(nodesAt(row, nodes)));
		s.fieldDecorators = decorators;
		s.metaValues = backEdges(nodesAt(a.symMetaValuesIdx[i], nodes));
		if (badRef(a.symCtorRoutineIdx[i], syms.length) || badRef(a.symCtorOwnerIdx[i], syms.length) || badRef(a.symBorrowedFromIdx[i], syms.length)) return false;
		s.ctorRoutine = a.symCtorRoutineIdx[i] >= 0 ? syms[a.symCtorRoutineIdx[i]] : null;
		s.ctorOwner = a.symCtorOwnerIdx[i] >= 0 ? syms[a.symCtorOwnerIdx[i]] : null;
		s.borrowedFrom = a.symBorrowedFromIdx[i] >= 0 ? syms[a.symBorrowedFromIdx[i]] : null;
	}
	return true;
}

export function linkNodes(this a: RowReader, rd: PackReader): boolean {
	const types = a.types;
	const syms = a.syms;
	const nodes = a.nodes;
	for (let i = 0; i < nodes.length; i += 1) {
		const n = nodes[i];
		n.nodeType = a.nodeTypeRef[i] >= 0 && a.nodeTypeRef[i] < types.length ? types[a.nodeTypeRef[i]] : null as unknown as Type;
		n.resolvedSym = a.nodeSymRef[i] >= 0 && a.nodeSymRef[i] < syms.length ? syms[a.nodeSymRef[i]] : null as unknown as Symbol;
		n.typeExpr = nd(a.nodeTeRef[i], nodes) as Node;
		const tes = a.nodeTesIdx[i];
		const bes = a.nodeBesIdx[i];
		const defaults = a.nodeDefaultsIdx[i];
		const pss = a.nodePssIdx[i];
		if (!refsFit(tes, nodes.length, true) || !refsFit(bes, nodes.length, true) || !refsFit(defaults, nodes.length, true)
			|| !refsFit(pss, syms.length, false) || badRef(a.nodeTypeAstRef[i], nodes.length)) return false;
		n.typeExprs = tes == null ? null : nodesAt(tes, nodes);
		n.genericDefaults = defaults == null ? null : optionalNodesAt(defaults, nodes);
		n.baseExprs = bes == null ? null : nodesAt(bes, nodes);
		n.nodeTypeAst = nd(a.nodeTypeAstRef[i], nodes);
		n.paramSyms = pss == null ? null : symsAt(pss, syms);
		rd.pos = a.nodePayloadPos[i] < 0 ? rd.b.length : a.nodePayloadPos[i];
		rd.last = a.nodePayloadPos[i] < 0 ? 10 : 9;
		n.data = buildNodeData(n.kind, rd, nodes, types);
	}
	return !rd.bad;
}

test "rowCodec: escape/unescape roundtrip incl separators" {
	const cases: string[] = ["", "plain", "with space", "tab\there", "line\nbreak", "comma,here", "back\\slash", "a\\nb\\tc,d\\e", "vietnamese:ttiếng Việt đũ ề"];
	for (const c of cases) {
		assert unescapeP(escapeP(c)) == c;
		assert splitCsv(joinCsv([c, c])).length == 2;
		assert splitCsv(joinCsv([c, c]))[0] == c;
	}
	assert joinCsv([]) == "-";
	assert splitCsv("-").length == 0;
	assert intsCsv([1, 2, 3]) == "1,2,3";
	// ASCII-forcing invariant: the escaped form must never carry a byte >= 0x80.
	const esc = escapeP("ttiếng Việt đũ ề");
	let maxByte = 0;
	let i = 0;
	while (i < esc.length) {
		const c = esc.charCodeAt(i);
		if (c > maxByte) maxByte = c;
		i = i + 1;
	}
	assert maxByte < 128;
}

function roundtripRows(w: RowWriter): RowReader | null {
	w.closeOver();
	const lines: string[] = [];
	w.emitObjectRows(lines);
	const rd = new PackReader(lines.join("\n"));
	const r = new RowReader();
	for (let tag = rd.startRow(); tag >= 0; tag = rd.startRow()) {
		if (!r.readObjectRow(tag, rd) || rd.bad) return null;
	}
	return r.linkTypesAndSymbols() && r.linkNodes(rd) ? r : null;
}

test "rowCodec: a symbol keeps its field decorators, meta entries and nonisolated fields" {
	const owner = makeSymbolState("Owner", SymbolKind.Class, null, false, SymbolState.Checked);
	const tag = createNodeAt(NodeKind.Identifier, { name: "tag" } as NodeData, makeLoc(1, 2));
	const meta = createNodeAt(NodeKind.StringLiteral, { value: "v" } as NodeData, makeLoc(2, 3));
	owner.fieldDecoratorNames = ["first", "second"];
	owner.fieldDecorators = [[tag], []];
	owner.metaKeys = ["key"];
	owner.metaValues = [meta];
	owner.nonisolatedFields = ["shared"];
	const w = new RowWriter();
	w.enqSym(owner, true);
	const r = roundtripRows(w);
	assert r != null;
	const got = r.syms[w.idxSym(owner)];
	assert got != owner;
	assert got.fieldDecoratorNames.length == 2 && got.fieldDecoratorNames[0] == "first" && got.fieldDecoratorNames[1] == "second";
	assert got.fieldDecorators.length == 2 && got.fieldDecorators[0].length == 1 && got.fieldDecorators[1].length == 0;
	assert got.fieldDecorators[0][0] == r.nodes[w.idxNode(tag)] && got.fieldDecorators[0][0] != tag;
	assert got.metaKeys.length == 1 && got.metaKeys[0] == "key";
	assert got.metaValues.length == 1 && got.metaValues[0] == r.nodes[w.idxNode(meta)] && got.metaValues[0] != meta;
	assert got.nonisolatedFields.length == 1 && got.nonisolatedFields[0] == "shared";
}

test "rowCodec: a symbol keeps its item identity, constructor links and the symbol it borrows from" {
	const owner = makeSymbolState("Owner", SymbolKind.Class, null, false, SymbolState.Checked);
	const routine = makeSymbolState("Owner_init", SymbolKind.Function, null, false, SymbolState.Checked);
	const lender = makeSymbolState("lender", SymbolKind.Variable, null, false, SymbolState.Checked);
	owner.itemModule = 4;
	owner.item = 9;
	owner.ctorRoutine = routine;
	routine.ctorOwner = owner;
	owner.borrowedFrom = lender;
	const w = new RowWriter();
	w.enqSym(owner, true);
	const r = roundtripRows(w);
	assert r != null;
	const got = r.syms[w.idxSym(owner)];
	assert got.itemModule == 4 && got.item == 9;
	const gotRoutine = got.ctorRoutine;
	assert gotRoutine != null && gotRoutine == r.syms[w.idxSym(routine)] && gotRoutine != routine;
	assert gotRoutine.ctorOwner == got;
	assert got.borrowedFrom == r.syms[w.idxSym(lender)] && got.borrowedFrom != lender;
}

test "rowCodec: a type keeps its owned and plain forms" {
	const plain = emptyType();
	plain.kind = TypeKind.Ref;
	plain.typeName = "Plain";
	const owned = emptyType();
	owned.kind = TypeKind.Ref;
	owned.typeName = "Owned";
	plain.ownedType = owned;
	owned.plainType = plain;
	const w = new RowWriter();
	w.enqType(plain);
	const r = roundtripRows(w);
	assert r != null;
	const gotPlain = r.types[w.idxType(plain)];
	const gotOwned = r.types[w.idxType(owned)];
	assert gotPlain != plain && gotOwned != owned;
	assert gotPlain.ownedType == gotOwned && gotOwned.plainType == gotPlain;
}

test "rowCodec: a node keeps its type syntax and reads back without a flow node" {
	const syntax = createNodeAt(NodeKind.Identifier, { name: "int32" } as NodeData, makeLoc(1, 8));
	const read = createNodeAt(NodeKind.Identifier, { name: "x" } as NodeData, makeLoc(1, 1));
	read.nodeTypeAst = syntax;
	read.flowNode = new FlowNode();
	const w = new RowWriter();
	w.enqNode(read);
	const r = roundtripRows(w);
	assert r != null;
	const got = r.nodes[w.idxNode(read)];
	assert got.nodeTypeAst == r.nodes[w.idxNode(syntax)] && got.nodeTypeAst != null && got.nodeTypeAst != syntax;
	assert got.flowNode == null;
}

test "rowCodec: a well-known type reads back as the process's own object" {
	const known = wellKnownTypes();
	const holder = emptyType();
	holder.kind = TypeKind.Tuple;
	holder.typeChildren = known;
	holder.typeReturn = createResult(getSysType(TypeKind.Int32), getSysType(TypeKind.String));
	const w = new RowWriter();
	w.enqType(holder);
	const r = roundtripRows(w);
	assert r != null;
	const got = r.types[w.idxType(holder)];
	assert got != holder && got.typeChildren.length == known.length;
	for (let k = 0; k < known.length; k += 1) assert got.typeChildren[k] == known[k];
	assert r.types[w.idxType(getSysType(TypeKind.String))] == getSysType(TypeKind.String);
	let params = 0;
	for (const t of w.types) {
		if (t.kind != TypeKind.GenericParam) continue;
		assert known.indexOf(t) >= 0 && r.types[w.idxType(t)] == t;
		params += 1;
	}
	assert params == known.filter((t: Type): boolean => t.kind == TypeKind.GenericParam).length;
	assert r.types[w.idxType(holder.typeReturn)] != holder.typeReturn;
}

test "rowCodec: a node an inlining copied is refused at write" {
	const copied = createNodeAt(NodeKind.Identifier, { name: "x" } as NodeData, makeLoc(1, 1));
	copied.inlineFrame = new InlineFrame("callee", null, 3);
	const w = new RowWriter();
	w.enqNode(copied);
	w.closeOver();
	let message = "";
	try {
		w.emitObjectRows([]);
	} catch (e) {
		message = (e as Error).message;
	}
	assert message.startsWith("internal:") && message.includes("inlineFrame");
}

function sameStrs(got: string[] | null, want: string[] | null): boolean {
	if (got == null || want == null) return got == null && want == null;
	if (got.length != want.length) return false;
	for (let k = 0; k < want.length; k += 1) {
		if (got[k] != want[k]) return false;
	}
	return true;
}

function sameTypes(got: Type[] | null, want: Type[] | null): boolean {
	if (got == null || want == null) return got == null && want == null;
	if (got.length != want.length) return false;
	for (let k = 0; k < want.length; k += 1) {
		if (got[k] != want[k]) return false;
	}
	return true;
}

function fieldReader(field: string): PackReader {
	const rd = new PackReader(`Q\t${field}\n`);
	rd.startRow();
	return rd;
}

test "rowCodec: a list field tells null, the empty list and empty strings apart" {
	assert strListText(null) == "-" && strListText([]) == "0:" && strListText([""]) == "1:";
	assert strListText(["", "a,b"]) == "2:,a\\cb";
	assert intListText(null) == "-" && intListText([]) == "0:" && intListText([-1]) == "1:-1";
	const cases: string[] = ["-", "0:", "1:", "2:,a\\cb", "1:-"];
	const wants: (string[] | null)[] = [null, [], [""], ["", "a,b"], ["-"]];
	for (let k = 0; k < cases.length; k += 1) {
		const rd = fieldReader(cases[k]);
		assert sameStrs(rd.nullableStrs(), wants[k]) && !rd.bad, cases[k];
	}
	const none = fieldReader("-");
	assert none.nullableInts() == null && !none.bad;
	const empty = fieldReader("0:").nullableInts();
	assert empty != null && empty.length == 0;
	const one = fieldReader("1:-1").nullableInts();
	assert one != null && one.length == 1 && one[0] == -1;
}

test "rowCodec: a list field whose count does not match its items is a failed read" {
	for (const field of ["2:a", "1:a,b", "0:a", "0:,", ":a", "x:", "", "3", "99999999999:"]) {
		const rd = fieldReader(field);
		rd.nullableStrs();
		assert rd.bad, `strings ${field}`;
	}
	for (const field of ["2:1", "1:1,2", "1:", "1:x", "1:1x", "1:-", "0:,", "1:2147483648"]) {
		const rd = fieldReader(field);
		rd.nullableInts();
		assert rd.bad, `ints ${field}`;
	}
	for (const field of ["-", "1:-", "2:0:", "1:1:0;0:", "1:"]) {
		const rd = fieldReader(field);
		rd.idRows();
		assert rd.bad, `rows ${field}`;
	}
	const listOfNoNull = fieldReader("-");
	listOfNoNull.strList();
	assert listOfNoNull.bad;
}

test "rowCodec: a type keeps typeNames and optionalFields exactly, null and empty strings included" {
	const cases: (string[] | null)[] = [null, [], [""], ["", "a,b"]];
	for (const names of cases) {
		const t = emptyType();
		t.kind = TypeKind.Struct;
		t.typeName = "Shape";
		t.optionalFields = names;
		t.typeNames = names ?? ["x"];
		const w = new RowWriter();
		w.enqType(t);
		const r = roundtripRows(w);
		assert r != null;
		const got = r.types[w.idxType(t)];
		assert got != t && sameStrs(got.optionalFields, names) && sameStrs(got.typeNames, names ?? ["x"]);
	}
}

test "rowCodec: a symbol's string lists keep empty strings and separators" {
	const cases: string[][] = [[], [""], ["", "a,b"]];
	for (const names of cases) {
		const s = makeSymbolState("Owner", SymbolKind.Class, null, false, SymbolState.Checked);
		s.fieldDecoratorNames = names;
		s.metaKeys = names;
		s.nonisolatedFields = names;
		const w = new RowWriter();
		w.enqSym(s, true);
		const r = roundtripRows(w);
		assert r != null;
		const got = r.syms[w.idxSym(s)];
		assert sameStrs(got.fieldDecoratorNames, names) && sameStrs(got.metaKeys, names) && sameStrs(got.nonisolatedFields, names);
	}
}

function instanceRoundtrip(args: Type[] | null, params: Type[] | null): boolean {
	const s = makeSymbolState("Box", SymbolKind.Class, null, false, SymbolState.Checked);
	s.instanceArgs = args;
	s.instanceParams = params;
	const w = new RowWriter();
	w.enqSym(s, true);
	const r = roundtripRows(w);
	if (r == null) return false;
	const got = r.syms[w.idxSym(s)];
	return sameTypes(got.instanceArgs, args) && sameTypes(got.instanceParams, params);
}

function subclassesRoundtrip(subs: Type[] | null): boolean {
	const s = makeSymbolState("Base", SymbolKind.Class, null, false, SymbolState.Checked);
	s.subclasses = subs;
	const w = new RowWriter();
	w.enqSym(s, true);
	const r = roundtripRows(w);
	return r != null && sameTypes(r.syms[w.idxSym(s)].subclasses, subs);
}

test "rowCodec: a symbol keeps instanceArgs and instanceParams apart, null and empty included" {
	const i32 = getSysType(TypeKind.Int32);
	const str = getSysType(TypeKind.String);
	assert instanceRoundtrip([i32], null);
	assert instanceRoundtrip(null, [str]);
	assert instanceRoundtrip([], null);
	assert instanceRoundtrip(null, []);
	assert instanceRoundtrip(null, null);
	assert instanceRoundtrip([i32], [str]);
}

test "rowCodec: a symbol keeps its noted subclasses, none noted apart from an empty list" {
	assert subclassesRoundtrip([getSysType(TypeKind.Int32), getSysType(TypeKind.String)]);
	assert subclassesRoundtrip([]);
	assert subclassesRoundtrip(null);
}

test "rowCodec: a node's header lists keep null, the empty list and null entries" {
	const syntax = createNodeAt(NodeKind.Identifier, { name: "T" } as NodeData, makeLoc(1, 1));
	const bare = createNodeAt(NodeKind.Identifier, { name: "bare" } as NodeData, makeLoc(2, 1));
	const emptied = createNodeAt(NodeKind.Identifier, { name: "emptied" } as NodeData, makeLoc(3, 1));
	emptied.typeExprs = [];
	emptied.genericDefaults = [];
	emptied.baseExprs = [];
	emptied.paramLocations = [];
	emptied.paramSyms = [];
	const holed = createNodeAt(NodeKind.Identifier, { name: "holed" } as NodeData, makeLoc(4, 1));
	holed.typeExprs = [syntax, null as unknown as Node];
	holed.genericDefaults = [null, syntax];
	holed.baseExprs = [null as unknown as Node];
	holed.paramLocations = [makeLocRange(-1, 2, 3, 4), null as unknown as SourceLocation];
	const w = new RowWriter();
	w.enqNode(bare);
	w.enqNode(emptied);
	w.enqNode(holed);
	const r = roundtripRows(w);
	assert r != null;
	const gotSyntax = r.nodes[w.idxNode(syntax)];
	const b = r.nodes[w.idxNode(bare)];
	assert b.typeExprs == null && b.genericDefaults == null && b.baseExprs == null && b.paramLocations == null && b.paramSyms == null;
	const e = r.nodes[w.idxNode(emptied)];
	assert e.typeExprs != null && e.typeExprs.length == 0 && e.genericDefaults != null && e.genericDefaults.length == 0;
	assert e.baseExprs != null && e.baseExprs.length == 0 && e.paramLocations != null && e.paramLocations.length == 0;
	assert e.paramSyms != null && e.paramSyms.length == 0;
	const h = r.nodes[w.idxNode(holed)];
	assert h.typeExprs != null && h.typeExprs.length == 2 && h.typeExprs[0] == gotSyntax && h.typeExprs[1] == null;
	assert h.genericDefaults != null && h.genericDefaults.length == 2 && h.genericDefaults[0] == null && h.genericDefaults[1] == gotSyntax;
	assert h.baseExprs != null && h.baseExprs.length == 1 && h.baseExprs[0] == null;
	assert h.paramLocations != null && h.paramLocations.length == 2 && h.paramLocations[1] == null;
	const l = h.paramLocations[0];
	assert l.line == -1 && l.column == 2 && l.endLine == 3 && l.endColumn == 4;
}

test "rowCodec: a payload's string lists keep empty strings and separators" {
	const cases: string[][] = [[], [""], ["", "a,b"]];
	for (const names of cases) {
		const decl = createNodeAt(NodeKind.InterfaceDecl, { interfaceName: "I", interfaceFields: names, interfaceFieldTypes: names, interfaceExtends: names, nameLocation: makeLoc(1, 1), interfaceFieldVisibility: names, interfaceFieldDecorators: [], interfaceOptionalFields: names, nativeName: "" } as NodeData, makeLoc(1, 1));
		const w = new RowWriter();
		w.enqNode(decl);
		const r = roundtripRows(w);
		assert r != null;
		const d = r.nodes[w.idxNode(decl)].data as InterfaceDeclData;
		assert sameStrs(d.interfaceFields, names) && sameStrs(d.interfaceFieldTypes, names) && sameStrs(d.interfaceExtends, names);
		assert sameStrs(d.interfaceFieldVisibility, names) && sameStrs(d.interfaceOptionalFields, names);
	}
}

test "rowCodec: a payload's nested node lists keep empty rows and null entries" {
	const tag = createNodeAt(NodeKind.Identifier, { name: "tag" } as NodeData, makeLoc(1, 1));
	const cases: Node[][][] = [[], [[]], [[], [tag, null as unknown as Node]]];
	for (const rows of cases) {
		const decl = createNodeAt(NodeKind.InterfaceDecl, { interfaceName: "I", interfaceFields: [], interfaceFieldTypes: [], interfaceExtends: [], nameLocation: makeLoc(1, 1), interfaceFieldVisibility: [], interfaceFieldDecorators: rows, interfaceOptionalFields: [], nativeName: "" } as NodeData, makeLoc(1, 1));
		const w = new RowWriter();
		w.enqNode(decl);
		const r = roundtripRows(w);
		assert r != null;
		const got = (r.nodes[w.idxNode(decl)].data as InterfaceDeclData).interfaceFieldDecorators;
		assert got.length == rows.length;
		for (let k = 0; k < rows.length; k += 1) {
			assert got[k].length == rows[k].length;
			for (let j = 0; j < rows[k].length; j += 1) {
				const want = rows[k][j];
				assert want == null ? got[k][j] == null : got[k][j] == r.nodes[w.idxNode(want)];
			}
		}
	}
}

test "rowCodec: a payload keeps float, location and node lists, null entries and a null location" {
	const init = createNodeAt(NodeKind.Identifier, { name: "init" } as NodeData, makeLoc(1, 1));
	const full = createNodeAt(NodeKind.EnumDecl, { enumName: "E", enumMembers: ["", "b"], enumValues: [-1.5, 0.25], nameLocation: null as unknown as SourceLocation, memberLocations: [makeLocRange(-1, 2, 3, 4), null as unknown as SourceLocation], enumInits: [null as unknown as Node, init] } as NodeData, makeLoc(1, 1));
	const empty = createNodeAt(NodeKind.EnumDecl, { enumName: "F", enumMembers: [], enumValues: [], nameLocation: makeLocRange(5, 6, 7, 8), memberLocations: [], enumInits: [] } as NodeData, makeLoc(2, 1));
	const w = new RowWriter();
	w.enqNode(full);
	w.enqNode(empty);
	const r = roundtripRows(w);
	assert r != null;
	const f = r.nodes[w.idxNode(full)].data as EnumDeclData;
	assert f.enumValues.length == 2 && f.enumValues[0] == -1.5 && f.enumValues[1] == 0.25;
	assert f.nameLocation == null;
	assert f.memberLocations.length == 2 && f.memberLocations[0].line == -1 && f.memberLocations[0].endColumn == 4 && f.memberLocations[1] == null;
	assert f.enumInits.length == 2 && f.enumInits[0] == null && f.enumInits[1] == r.nodes[w.idxNode(init)];
	const e = r.nodes[w.idxNode(empty)].data as EnumDeclData;
	assert e.enumValues.length == 0 && e.memberLocations.length == 0 && e.enumInits.length == 0 && e.enumMembers.length == 0;
	assert e.nameLocation.line == 5 && e.nameLocation.column == 6 && e.nameLocation.endLine == 7 && e.nameLocation.endColumn == 8;
}

function refusalAtWrite(n: Node): string {
	const w = new RowWriter();
	w.enqNode(n);
	w.closeOver();
	try {
		w.emitObjectRows([]);
	} catch (e) {
		return (e as Error).message;
	}
	return "";
}

test "rowCodec: a field only a transform writes is refused at write when it left its parser default" {
	const a = createNodeAt(NodeKind.Identifier, { name: "a" } as NodeData, makeLoc(1, 1));
	const loc = makeLoc(2, 1);
	const cases: Node[] = [
		createNodeAt(NodeKind.ForStmt, { forInit: a, forCondition: a, forUpdate: a, forBody: a, forLabel: "__lp1" } as NodeData, loc),
		createNodeAt(NodeKind.ForOfStmt, { forOfBinding: "x", forOfIsConst: true, forOfIterable: a, forOfBody: a, forOfPattern: null as unknown as Node, bindingLocation: loc, forOfLabel: "__lp2" } as NodeData, loc),
		createNodeAt(NodeKind.ForInStmt, { forInBinding: "k", forInIsConst: true, forInObject: a, forInBody: a, forInLabel: "__lp3" } as NodeData, loc),
		createNodeAt(NodeKind.DoWhileStmt, { doBody: a, doCondition: a, dwLabel: "__lp4", dwSwitchWrapper: false } as NodeData, loc),
		createNodeAt(NodeKind.DoWhileStmt, { doBody: a, doCondition: a, dwLabel: "", dwSwitchWrapper: true } as NodeData, loc),
		createNodeAt(NodeKind.SwitchStmt, { switchDisc: a, switchCases: [], switchLowered: true } as NodeData, loc),
	];
	const fields = ["forLabel", "forOfLabel", "forInLabel", "dwLabel", "dwSwitchWrapper", "switchLowered"];
	for (let k = 0; k < cases.length; k += 1) {
		const message = refusalAtWrite(cases[k]);
		assert message.startsWith("internal:") && message.includes(fields[k]), fields[k];
	}
	const atDefault = createNodeAt(NodeKind.SwitchStmt, { switchDisc: a, switchCases: [], switchLowered: false } as NodeData, loc);
	assert refusalAtWrite(atDefault) == "";
}
