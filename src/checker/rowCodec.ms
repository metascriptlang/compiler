import { Symbol, SymbolFlag, NodeFlag, SymbolKind, SymbolState, Type, TypeKind, TypeFlag, Node, NodeData, NodeKind, SourceLocation, CallingConvention, makeLoc, makeLocRange, createNodeAt, DeclKind, ExternKind, BuiltinKind, FlowNode, InlineFrame } from "../ast/node";
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

// Fast int-list scan: digit accumulation straight off charCodeAt (O(1) on the
// ASCII pack), no per-element substring allocation. Escape sequences never
// occur in int lists, so the separator scan can ignore backslashes.
function parseIntsCsv(s: string): int32[] {
	if (s == "-" || s == "") return [];
	const out: int32[] = [];
	let i = 0;
	const n = s.length;
	while (i < n) {
		let neg = false;
		if (s.charCodeAt(i) == 45) {
			neg = true;
			i = i + 1;
		}
		let v: int32 = 0;
		while (i < n) {
			const c = s.charCodeAt(i);
			if (c >= 48 && c <= 57) {
				v = v * 10 + (c - 48);
				i = i + 1;
				continue;
			}
			break;
		}
		out.push(neg ? -v : v);
		i = i + 1;
	}
	return out;
}

// Scan with charCodeAt (O(1) on the ASCII pack) + one slice per element.
// The old char-concat builder (`cur = cur + ch`) allocated a fresh string per
// character — quadratic per field, and the reader splits hundreds of thousands
// of them.
function splitCsvRaw(s: string): string[] {
	if (s == "") return [];
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
			out.push(s.slice(start, i));
			start = i + 1;
		}
		i = i + 1;
	}
	if (n > start || out.length > 0) out.push(s.slice(start, n));
	return out;
}

function floatsCsv(arr: number[] | null): string {
	if (arr == null) return "-";
	if (arr.length == 0) return "";
	let out = "";
	let i = 0;
	while (i < arr.length) {
		if (i > 0) out = out + ",";
		out = out + `${arr[i]}`;
		i = i + 1;
	}
	return out;
}

function parseFloatsCsv(s: string): number[] {
	if (s == "-" || s == "") return [];
	const parts = splitCsvRaw(s);
	const out: number[] = [];
	for (const p of parts) out.push(p.parseFloat());
	return out;
}

function locCsv4(loc: SourceLocation | null): string {
	if (loc == null) return "0,0,0,0";
	return `${loc.line},${loc.column},${loc.endLine},${loc.endColumn}`;
}

// SourceLocation[] flattening: "-" = null, "" = empty, else 4 ints per loc.
function locsCsv(locs: SourceLocation[] | null): string {
	if (locs == null) return "-";
	if (locs.length == 0) return "";
	let out = "";
	let i = 0;
	while (i < locs.length) {
		if (i > 0) out = out + ",";
		out = out + locCsv4(locs[i]);
		i = i + 1;
	}
	return out;
}

function parseLoc(s: string): SourceLocation {
	const p = parseIntsCsv(s);
	if (p.length == 0) return makeLoc(0, 0);
	const l = makeLoc(p[0], p.length > 1 ? p[1] : 0);
	if (p.length > 2) l.endLine = p[2];
	if (p.length > 3) l.endColumn = p[3];
	return l;
}

function parseLocs(s: string): SourceLocation[] {
	if (s == "-" || s == "") return [];
	const p = parseIntsCsv(s);
	const out: SourceLocation[] = [];
	let k = 0;
	while (k + 3 < p.length) {
		const l = makeLoc(p[k], p[k + 1]);
		l.endLine = p[k + 2];
		l.endColumn = p[k + 3];
		out.push(l);
		k = k + 4;
	}
	return out;
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
	if (arr.length == 0) return "";
	let out = "";
	let i = 0;
	while (i < arr.length) {
		if (i > 0) out = out + ",";
		out = out + idxNodeP(arr[i]);
		i = i + 1;
	}
	return out;
}

function nestedIdxsP(arrs: Node[][] | null): string {
	if (arrs == null) return "-";
	let out = "";
	let i = 0;
	while (i < arrs.length) {
		out = out + idxsP(arrs[i]) + ";";
		i = i + 1;
	}
	return out;
}

// Emit-phase sink: appends each field's serialized column. Byte-for-byte the
// same output the pre-sink emitNodePayload produced (join("\t") === the old
// template's \t separators) — verified by pack byte-identity.
let _payloadCols: string[] = [];

const emitSink: FieldSink = {
	node: (name: string, x: Node | null): void => { _payloadCols.push(`${idxNodeP(x)}`); },
	nodes: (name: string, a: Node[] | null): void => { _payloadCols.push(idxsP(a)); },
	nodesNested: (name: string, a: Node[][] | null): void => { _payloadCols.push(nestedIdxsP(a)); },
	typ: (name: string, t: Type | null): void => { _payloadCols.push(`${idxTypeP(t)}`); },
	str: (name: string, s: string): void => { _payloadCols.push(escapeP(s)); },
	strArr: (name: string, a: string[] | null): void => { _payloadCols.push(joinCsv(a != null ? a : [])); },
	integer: (name: string, v: int64): void => { _payloadCols.push(`${v}`); },
	float: (name: string, v: float64): void => { _payloadCols.push(`${v}`); },
	bool: (name: string, b: boolean): void => { _payloadCols.push(b ? "1" : "0"); },
	loc: (name: string, l: SourceLocation | null): void => { _payloadCols.push(locCsv4(l)); },
	locs: (name: string, l: SourceLocation[] | null): void => { _payloadCols.push(locsCsv(l)); },
	floats: (name: string, a: number[] | null): void => { _payloadCols.push(floatsCsv(a)); },
};

function emitNodePayloadViaSink(n: Node): string {
	_payloadCols = [];
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

// A field that is usually "-", read without a slice.
export function dashOrStr(this r: PackReader): string {
	const n = r.b.length;
	if (r.last == 9 && r.pos < n && r.b[r.pos] == 45 && (r.pos + 1 == n || r.b[r.pos + 1] == 9 || r.b[r.pos + 1] == 10)) {
		r.finish(r.pos + 1);
		return "-";
	}
	return r.str();
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

// Same reading as parseNodeArr: "-" and "" are the empty list; an index outside the pack reads as null.
export function nodeArr(this r: PackReader, nodes: Node[]): Node[] {
	const out: Node[] = [];
	for (const v of r.ints()) out.push(v >= 0 && v < nodes.length ? nodes[v] : null as unknown as Node);
	return out;
}

// Same reading as parseIntsCsv: "-" and "" are the empty list, anything after a number is skipped.
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

// idxs-convention parse: "-" = null, "0" = empty, else comma list of N idx.
// idxs-convention parse: "-"/"" = empty list; a bare "0" is a REAL one-element
// list [nodes[0]] — the empty marker is "" (writer idxs/idxsP), never "0".
// Digit accumulation straight off charCodeAt (O(1) on the ASCII pack).
function parseNodeIdxList(s: string, nodes: Node[]): (Node | null)[] {
	if (s == "-" || s == "") return [];
	const out: (Node | null)[] = [];
	let i = 0;
	const n = s.length;
	while (i < n) {
		let neg = false;
		if (s.charCodeAt(i) == 45) {
			neg = true;
			i = i + 1;
		}
		let v: int32 = 0;
		while (i < n) {
			const c = s.charCodeAt(i);
			if (c >= 48 && c <= 57) {
				v = v * 10 + (c - 48);
				i = i + 1;
				continue;
			}
			break;
		}
		const idx = neg ? -v : v;
		out.push(idx >= 0 && idx < nodes.length ? nodes[idx] : null);
		i = i + 1;
	}
	return out;
}

function parseNodeArr(s: string, nodes: Node[]): Node[] {
	const r = parseNodeIdxList(s, nodes);
	const out: Node[] = [];
	for (const n of r) out.push(n != null ? n : null as unknown as Node);
	return out;
}

function nd(i: int32, nodes: Node[]): Node | null {
	return i >= 0 && i < nodes.length ? nodes[i] : null;
}

function splitRows(s: string): string[] {
	const out: string[] = [];
	let cur = "";
	let i = 0;
	while (i < s.length) {
		const ch = s.charAt(i);
		if (ch == ";") {
			out.push(cur);
			cur = "";
		} else {
			cur = cur + ch;
		}
		i = i + 1;
	}
	return out;
}

function parseNestedNodeArrs(s: string, nodes: Node[]): Node[][] {
	if (s == "-" || s == "") return [];
	const parts = splitRows(s);
	const out: Node[][] = [];
	for (const p of parts) out.push(parseNodeArr(p, nodes));
	return out;
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
	if (kind == NodeKind.CallExpr) return { callee: rd.nodeRef(nodes) as Node, arguments: rd.nodeArr(nodes), isDirectCall: rd.flag(), resolvedOverloadIdx: rd.str().parseFloat() } as NodeData;
	if (kind == NodeKind.MemberExpr) return { object: rd.nodeRef(nodes) as Node, property: rd.text(), isOptional: rd.flag() } as NodeData;
	if (kind == NodeKind.ArrayAccess) return { array: rd.nodeRef(nodes) as Node, index: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.ObjectLiteral) return { properties: rd.nodeArr(nodes), keys: splitCsv(rd.str()), keyLocations: parseLocs(rd.str()) } as NodeData;
	if (kind == NodeKind.ArrayLiteral) return { elements: rd.nodeArr(nodes) } as NodeData;
	if (kind == NodeKind.ArrowFunction) return { arrowParams: splitCsv(rd.str()), arrowParamTypes: splitCsv(rd.str()), arrowBody: rd.nodeRef(nodes) as Node, arrowFlags: rd.text(), arrowReturnType: rd.text(), arrowDefaults: rd.nodeArr(nodes) } as NodeData;
	if (kind == NodeKind.FunctionExpr) return { funcExprParams: splitCsv(rd.str()), funcExprParamTypes: splitCsv(rd.str()), funcExprBody: rd.nodeRef(nodes) as Node, funcExprFlags: rd.text(), funcExprReturnType: rd.text() } as NodeData;
	if (kind == NodeKind.TypeAssertion) return { asExpr: rd.nodeRef(nodes) as Node, asType: rd.text() } as NodeData;
	if (kind == NodeKind.ConditionalExpr) return { ternaryCondition: rd.nodeRef(nodes) as Node, ternaryConsequent: rd.nodeRef(nodes) as Node, ternaryAlternate: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.SpreadExpr) return { spreadArg: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.NewExpr) return { newCallee: rd.nodeRef(nodes) as Node, newArguments: rd.nodeArr(nodes) } as NodeData;
	if (kind == NodeKind.TryExpr) return { tryArg: rd.nodeRef(nodes) as Node, hasCatch: rd.flag(), catchVal: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.MatchExpr) return { matchDisc: rd.nodeRef(nodes) as Node, matchCases: rd.nodeArr(nodes) } as NodeData;
	if (kind == NodeKind.MatchCase) return { casePatterns: rd.nodeArr(nodes), caseGuard: rd.nodeRef(nodes) as Node, caseBody: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.AwaitExpr) return { awaitArg: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.YieldExpr) return { yieldArg: rd.nodeRef(nodes) as Node, isDelegate: rd.flag() } as NodeData;
	if (kind == NodeKind.MoveExpr) return { moveArg: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.OutExpr) return { outArg: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.SizeofExpr) return { sizeofType: rd.text(), sizeofResolved: rd.typeRef(types) as Type } as NodeData;
	if (kind == NodeKind.HiddenStdConv || kind == NodeKind.HiddenSubConv) return { convExpr: rd.nodeRef(nodes) as Node, convType: rd.typeRef(types) as Type } as NodeData;
	if (kind == NodeKind.HiddenDeref || kind == NodeKind.HiddenAddr) return { expr: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.TypeAnnotation) return { annotationType: rd.text() } as NodeData;
	if (kind == NodeKind.ArrayPattern) return { patternElements: rd.nodeArr(nodes), hasRestElement: rd.flag(), patternDefaults: rd.nodeArr(nodes) } as NodeData;
	if (kind == NodeKind.ObjectPattern) return { patternProps: rd.nodeArr(nodes), hasRestProp: rd.flag() } as NodeData;
	if (kind == NodeKind.ObjectPatternProp) return { propKey: rd.text(), propAlias: rd.nodeRef(nodes) as Node, propDefault: rd.nodeRef(nodes) } as NodeData;
	if (kind == NodeKind.DestructuringDecl) return { destrPattern: rd.nodeRef(nodes) as Node, destrInit: rd.nodeRef(nodes) as Node, destrIsConst: rd.flag(), destrType: rd.text() } as NodeData;
	if (kind == NodeKind.VariableDecl) return { declName: rd.text(), declType: rd.text(), initializer: rd.nodeRef(nodes) as Node, declKind: rd.dec() as DeclKind, nameLocation: parseLoc(rd.str()) } as NodeData;
	if (kind == NodeKind.IfStmt) return { condition: rd.nodeRef(nodes) as Node, consequent: rd.nodeRef(nodes) as Node, alternate: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.WhileStmt) return { whileCondition: rd.nodeRef(nodes) as Node, whileBody: rd.nodeRef(nodes) as Node, whileLabel: rd.text() } as NodeData;
	if (kind == NodeKind.ForStmt) return { forInit: rd.nodeRef(nodes) as Node, forCondition: rd.nodeRef(nodes) as Node, forUpdate: rd.nodeRef(nodes) as Node, forBody: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.ForOfStmt) return { forOfBinding: rd.text(), forOfIsConst: rd.flag(), forOfIterable: rd.nodeRef(nodes) as Node, forOfBody: rd.nodeRef(nodes) as Node, forOfPattern: rd.nodeRef(nodes) as Node, bindingLocation: parseLoc(rd.str()) } as NodeData;
	if (kind == NodeKind.ForInStmt) return { forInBinding: rd.text(), forInIsConst: rd.flag(), forInObject: rd.nodeRef(nodes) as Node, forInBody: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.BlockStmt) return { statements: rd.nodeArr(nodes) } as NodeData;
	if (kind == NodeKind.ExprStmt) return { expr: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.ReturnStmt) return { argument: rd.nodeRef(nodes) } as NodeData;
	if (kind == NodeKind.BreakStmt) return { breakLabel: rd.text() } as NodeData;
	if (kind == NodeKind.ContinueStmt) return { continueLabel: rd.text() } as NodeData;
	if (kind == NodeKind.FunctionDecl) return { fnName: rd.text(), params: splitCsv(rd.str()), fnParamTypes: splitCsv(rd.str()), fnBody: rd.nodeRef(nodes) as Node, fnFlags: rd.text(), fnReturnType: rd.text(), fnDefaults: rd.nodeArr(nodes), nativeName: rd.text(), nameLocation: parseLoc(rd.str()) } as NodeData;
	if (kind == NodeKind.DoWhileStmt) return { doBody: rd.nodeRef(nodes) as Node, doCondition: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.SwitchStmt) return { switchDisc: rd.nodeRef(nodes) as Node, switchCases: rd.nodeArr(nodes) } as NodeData;
	if (kind == NodeKind.SwitchCase) return { caseTests: rd.nodeArr(nodes), caseStmts: rd.nodeArr(nodes), isDefault: rd.flag() } as NodeData;
	if (kind == NodeKind.UnreachableStmt) return { unreachableMsg: rd.text() } as NodeData;
	if (kind == NodeKind.MatchStmt) return { matchStmtDisc: rd.nodeRef(nodes) as Node, matchStmtCases: rd.nodeArr(nodes) } as NodeData;
	if (kind == NodeKind.ImportDecl) return { importNames: splitCsv(rd.str()), importAliases: splitCsv(rd.str()), importSource: rd.text(), nameLocations: parseLocs(rd.str()), aliasLocations: parseLocs(rd.str()), importTypeNames: splitCsv(rd.str()) } as NodeData;
	if (kind == NodeKind.ExportDecl) return { exportedDecl: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.TypeAliasDecl) return { aliasName: rd.text(), aliasType: rd.text(), aliasIsDistinct: rd.flag(), aliasGenericParams: rd.text(), discriminantName: rd.text(), discriminantType: rd.text(), variantKeys: splitCsv(rd.str()), variantTypes: splitCsv(rd.str()), nameLocation: parseLoc(rd.str()) } as NodeData;
	if (kind == NodeKind.EnumDecl) return { enumName: rd.text(), enumMembers: splitCsv(rd.str()), enumValues: parseFloatsCsv(rd.str()), nameLocation: parseLoc(rd.str()), memberLocations: parseLocs(rd.str()), enumInits: rd.nodeArr(nodes) } as NodeData;
	if (kind == NodeKind.InterfaceDecl || kind == NodeKind.StructDecl) return { interfaceName: rd.text(), interfaceFields: splitCsv(rd.str()), interfaceFieldTypes: splitCsv(rd.str()), interfaceExtends: splitCsv(rd.str()), nameLocation: parseLoc(rd.str()), interfaceFieldVisibility: splitCsv(rd.str()), interfaceFieldDecorators: parseNestedNodeArrs(rd.str(), nodes), interfaceOptionalFields: splitCsv(rd.str()), nativeName: rd.text() } as NodeData;
	if (kind == NodeKind.ClassDecl) return { className: rd.text(), classDisplayName: rd.text(), classExtends: rd.text(), classBody: rd.nodeArr(nodes), nameLocation: parseLoc(rd.str()), classImplements: splitCsv(rd.str()) } as NodeData;
	if (kind == NodeKind.PropertyDecl) return { propName: rd.text(), propType: rd.text(), propIsStatic: rd.flag(), propIsReadonly: rd.flag(), propVisibility: rd.text(), propInitializer: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.MethodDecl) return { methodName: rd.text(), methodParams: splitCsv(rd.str()), methodParamTypes: splitCsv(rd.str()), methodBody: rd.nodeRef(nodes) as Node, methodIsStatic: rd.flag(), methodFlags: rd.text(), methodVisibility: rd.text(), methodReturnType: rd.text(), methodDefaults: rd.nodeArr(nodes), nativeName: rd.text(), nameLocation: parseLoc(rd.str()) } as NodeData;
	if (kind == NodeKind.ConstructorDecl) return { ctorParams: splitCsv(rd.str()), ctorParamTypes: splitCsv(rd.str()), ctorBody: rd.nodeRef(nodes) as Node, ctorDefaults: rd.nodeArr(nodes), ctorVisibility: rd.text(), ctorParamProps: rd.nodeArr(nodes), ctorFlags: rd.text() } as NodeData;
	if (kind == NodeKind.ThrowStmt) return { throwArg: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.TryCatchStmt) return { tryBody: rd.nodeRef(nodes) as Node, catchName: rd.text(), catchBody: rd.nodeRef(nodes) as Node, finallyBody: rd.nodeRef(nodes) as Node, catchBindingLocation: parseLoc(rd.str()), hasCatchClause: rd.flag() } as NodeData;
	if (kind == NodeKind.MacroInvocation) return { macroName: rd.text(), macroArgs: rd.nodeArr(nodes), macroHasParens: rd.last == 9 && rd.flag() } as NodeData;
	if (kind == NodeKind.DecoratedDecl) return { decorators: rd.nodeArr(nodes), decoratedNode: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.DeferStmt) return { deferExpr: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.TestDecl) return { testName: rd.text(), testBody: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.AssertStmt) return { assertExpr: rd.nodeRef(nodes) as Node, assertSource: rd.text(), assertMessage: rd.text(), assertMessageExpr: rd.nodeRef(nodes) } as NodeData;
	if (kind == NodeKind.ExternDecl) return { externKind: rd.dec() as ExternKind, externName: rd.text(), nativeName: rd.text(), externType: rd.text() } as NodeData;
	if (kind == NodeKind.MacroDecl) return { macroDeclName: rd.text(), macroDeclParams: splitCsv(rd.str()), macroDeclParamTypes: splitCsv(rd.str()), macroDeclReturnType: rd.text(), macroDeclBody: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.QuoteExpr) return { quoteBody: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.ComptimeBlock) return { comptimeBody: rd.nodeRef(nodes) as Node } as NodeData;
	if (kind == NodeKind.TypeGeneric) return { typExprBase: rd.nodeRef(nodes) as Node, typExprArgs: rd.nodeArr(nodes) } as NodeData;
	if (kind == NodeKind.TypeArray) return { typExprElement: rd.nodeRef(nodes) as Node, typExprSize: rd.str().parseFloat() } as NodeData;
	if (kind == NodeKind.TypeUnion) return { typExprMembers: rd.nodeArr(nodes), discFieldName: rd.text(), variantKeys: splitCsv(rd.str()), discKind: rd.text() } as NodeData;
	if (kind == NodeKind.TypeIntersection) return { typExprMembers: rd.nodeArr(nodes) } as NodeData;
	if (kind == NodeKind.TypeFunction) return { typExprParams: rd.nodeArr(nodes), typExprReturn: rd.nodeRef(nodes) as Node, typExprParamNames: splitCsv(rd.str()) } as NodeData;
	if (kind == NodeKind.TypeObject) return { typExprFieldNames: splitCsv(rd.str()), typExprFieldTypes: rd.nodeArr(nodes), typExprIndexKey: rd.nodeRef(nodes) as Node, typExprIndexValue: rd.nodeRef(nodes) as Node, typExprFieldDecorators: parseNestedNodeArrs(rd.str(), nodes), typExprTypeName: rd.text(), typExprOptionalFields: splitCsv(rd.str()) } as NodeData;
	if (kind == NodeKind.Program) return { programStmts: rd.nodeArr(nodes) } as NodeData;
	if (kind == NodeKind.ActorDecl) return { actorName: rd.text(), actorBody: rd.nodeArr(nodes), nameLocation: parseLoc(rd.str()) } as NodeData;
	if (kind == NodeKind.SpliceMany) return { spliceNodes: rd.nodeArr(nodes) } as NodeData;
	if (kind == NodeKind.JSXElement) return { jsxTag: rd.text(), jsxAttrs: rd.nodeArr(nodes), jsxChildren: rd.nodeArr(nodes), jsxSelfClosing: rd.flag() } as NodeData;
	if (kind == NodeKind.JSXFragment) return { jsxFragChildren: rd.nodeArr(nodes) } as NodeData;
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
	instanceArgs: encoded("S retained instArgsCsv"),
	instanceParams: encoded("S retained instParamsCsv"),
	ctorRoutine: encoded("S ctorRoutineIdx"),
	ctorOwner: encoded("S ctorOwnerIdx"),
	borrowedFrom: encoded("S borrowedFromIdx"),
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
//     ownerIdx typeParamsCsv originIdx paramOwnerIdx retained instArgsCsv instParamsCsv
//     fieldDecoratorNamesCsv fieldDecoratorRows metaKeysCsv metaValuesCsv nonisolatedCsv
//     itemModule item ctorRoutineIdx ctorOwnerIdx borrowedFromIdx

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
	if (arr.length == 0) return "";
	let out = "";
	let i = 0;
	while (i < arr.length) {
		if (i > 0) out = out + ",";
		out = out + w.idxNode(arr[i]);
		i = i + 1;
	}
	return out;
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
		const children: int32[] = [];
		if (t.typeChildren != null) {
			for (const c of t.typeChildren) children.push(w.idxType(c));
		}
		const names: string[] = t.typeNames != null ? t.typeNames : [];
		const optional: string[] = t.optionalFields != null ? t.optionalFields : [];
		const ops: int32[] = [];
		for (const o of t.attachedOps) ops.push(w.idxSym(o));
		lines.push(`T\t${i}\t${t.kind as int32}\t${t.typeFlags as uint32}\t${t.typeValue}\t${t.callConv as int32}\t${escapeP(t.typeName)}\t${joinCsv(names)}\t${intsCsv(children)}\t${w.idxType(t.typeReturn)}\t${w.idxType(t.typeExtra)}\t${w.idxSym(t.sym)}\t${joinCsv(optional)}\t${intsCsv(ops)}\t${w.idxType(t.readonlyView)}\t${w.idxType(t.mutableView)}\t${w.idxType(t.typeInst)}\t${w.idxType(t.typeParamDefault)}\t${w.idxType(t.ownedType)}\t${w.idxType(t.plainType)}\t${wellKnownIndex(wellKnown, t)}`);
	}

	_wnodeIdx = w.nodeIdx;
	_wtypeIdx = w.typeIdx;
	for (let i = 0; i < w.nodes.length; i += 1) {
		const n = w.nodes[i];
		if (n.inlineFrame != null) throw new Error(`internal: node ${i} (${n.kind.toString()}) carries an inlineFrame, which only transform-time inlining sets; the object rows hold checked trees`);
		const loc = n.location;
		const tes = n.typeExprs != null ? w.idxs(n.typeExprs) : "-";
		const bes = n.baseExprs != null ? w.idxs(n.baseExprs) : "-";
		const defaults: int32[] = [];
		if (n.genericDefaults != null) {
			for (const value of n.genericDefaults) defaults.push(w.idxNode(value));
		}
		const pls = locsCsv(n.paramLocations);
		let pss = "-";
		if (n.paramSyms != null) {
			const psi: int32[] = [];
			for (const ps of n.paramSyms) psi.push(w.idxSym(ps));
			pss = psi.length == 0 ? "" : intsCsv(psi);
		}
		lines.push(`N\t${i}\t${n.kind as int32}\t${n.flags as uint64}\t${loc.line}\t${loc.column}\t${loc.endLine}\t${loc.endColumn}\t${w.idxType(n.nodeType)}\t${w.idxSym(n.resolvedSym)}\t${w.idxNode(n.typeExpr)}\t${tes}\t${pls}\t${escapeP(n.typeArg)}\t${n.variantSlot}\t${pss}\t${bes}\t${n.genericDefaults == null ? "-" : intsCsv(defaults)}\t${w.idxNode(n.nodeTypeAst)}\t${emitNodePayloadViaSink(n)}`);
	}

	for (let i = 0; i < w.syms.length; i += 1) {
		const s = w.syms[i];
		const loc = s.location;
		const ovl: int32[] = [];
		if (s.overloads != null) {
			for (const ov of s.overloads) ovl.push(w.idxSym(ov));
		}
		const stf: int32[] = [];
		if (s.staticFields != null) {
			for (const sf of s.staticFields) stf.push(w.idxSym(sf));
		}
		const dp = w.idxs(s.defaultParams);
		const tps: int32[] = [];
		for (const tp of s.typeParams) tps.push(w.idxType(tp));
		const instArgs: int32[] = [];
		for (const t of s.instanceArgs ?? []) instArgs.push(w.idxType(t));
		const instParams: int32[] = [];
		for (const t of s.instanceParams ?? []) instParams.push(w.idxType(t));
		const retained = s.instanceArgs != null && s.instanceParams != null ? 1 : 0;
		lines.push(`S\t${i}\t${s.symbolKind as int32}\t${s.state as int32}\t${s.symFlags as uint64}\t${s.overloadIdx}\t${s.mutatedParams}\t${s.duVariantSlot}\t${loc !== null ? loc.line : 0}\t${loc !== null ? loc.column : 0}\t${loc !== null ? loc.endLine : 0}\t${loc !== null ? loc.endColumn : 0}\t${w.roots.has(s) ? 1 : 0}\t${escapeP(s.name)}\t${escapeP(s.modulePath)}\t${escapeP(s.nativeName)}\t${escapeP(builtinKindName(s.builtinKind))}\t${escapeP(s.headerPath)}\t${escapeP(s.jsModulePath)}\t${w.idxType(s.symbolType)}\t${intsCsv(ovl)}\t${intsCsv(stf)}\t${w.idxNode(s.declNode)}\t${dp}\t${s.disamb}\t${escapeP(s.exportName)}\t${w.idxSym(s.staticOwner)}\t${intsCsv(tps)}\t${w.idxSym(s.instantiatedFrom)}\t${w.idxSym(s.typeParamOwner)}\t${retained}\t${intsCsv(instArgs)}\t${intsCsv(instParams)}\t${joinCsv(s.fieldDecoratorNames)}\t${nestedIdxsP(s.fieldDecorators)}\t${joinCsv(s.metaKeys)}\t${w.idxs(s.metaValues)}\t${joinCsv(s.nonisolatedFields)}\t${s.itemModule}\t${s.item}\t${w.idxSym(s.ctorRoutine)}\t${w.idxSym(s.ctorOwner)}\t${w.idxSym(s.borrowedFrom)}`);
	}
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
	symRetained: boolean[] = [];
	symInstanceArgsIdx: int32[][] = [];
	symInstanceParamsIdx: int32[][] = [];
	symDpRaw: string[] = [];
	symFieldDecoratorsRaw: string[] = [];
	symMetaValuesRaw: string[] = [];
	symCtorRoutineIdx: int32[] = [];
	symCtorOwnerIdx: int32[] = [];
	symBorrowedFromIdx: int32[] = [];
	nodeTypeRef: int32[] = [];
	nodeSymRef: int32[] = [];
	nodeTeRef: int32[] = [];
	nodeTesRaw: string[] = [];
	nodeBesRaw: string[] = [];
	nodeDefaultsRaw: string[] = [];
	nodePlsRaw: string[] = [];
	nodePssRaw: string[] = [];
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
		t.typeNames = splitCsv(rd.str());
		a.typeChildrenIdx.push(rd.ints());
		a.typeReturnIdx.push(rd.int() as int32);
		a.typeExtraIdx.push(rd.int() as int32);
		a.typeSymIdx.push(rd.int() as int32);
		const optional = rd.str();
		if (optional != "-") t.optionalFields = splitCsv(optional);
		a.typeOpsIdx.push(rd.ints());
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
		a.nodeTesRaw.push(rd.dashOrStr());
		a.nodePlsRaw.push(rd.dashOrStr());
		n.typeArg = unescapeP(rd.str());
		n.variantSlot = rd.int() as int32;
		a.nodePssRaw.push(rd.dashOrStr());
		a.nodeBesRaw.push(rd.dashOrStr());
		a.nodeDefaultsRaw.push(rd.dashOrStr());
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
		a.symOverloadIdx.push(rd.ints());
		a.symStaticIdx.push(rd.ints());
		a.symDeclIdx.push(rd.int() as int32);
		a.symDpRaw.push(rd.str());
		if (rd.last == 9) s.disamb = rd.int() as int32;
		if (rd.last == 9) s.exportName = unescapeP(rd.str());
		a.symOwnerIdx.push(rd.last == 9 ? rd.int() as int32 : -1);
		a.symTypeParamsIdx.push(rd.last == 9 ? rd.ints() : []);
		a.symOriginIdx.push(rd.last == 9 ? rd.int() as int32 : -1);
		a.symParamOwnerIdx.push(rd.last == 9 ? rd.int() as int32 : -1);
		a.symRetained.push(rd.last == 9 && rd.int() == 1);
		a.symInstanceArgsIdx.push(rd.last == 9 ? rd.ints() : []);
		a.symInstanceParamsIdx.push(rd.last == 9 ? rd.ints() : []);
		s.fieldDecoratorNames = splitCsv(rd.str());
		a.symFieldDecoratorsRaw.push(rd.str());
		s.metaKeys = splitCsv(rd.str());
		a.symMetaValuesRaw.push(rd.str());
		s.nonisolatedFields = splitCsv(rd.str());
		s.itemModule = rd.int() as int32;
		s.item = rd.int() as int32;
		a.symCtorRoutineIdx.push(rd.int() as int32);
		a.symCtorOwnerIdx.push(rd.int() as int32);
		a.symBorrowedFromIdx.push(rd.int() as int32);
		a.syms.push(s);
		rd.endRow();
		return true;
	}
	return false;
}

function badRef(k: int32, count: int32): boolean {
	return k < -1 || k >= count;
}

function linkNodeList(raw: string, nodes: Node[]): Node[] | null {
	const out: Node[] = [];
	for (const k of parseIntsCsv(raw)) {
		if (badRef(k, nodes.length)) return null;
		out.push(k >= 0 ? nodes[k] : null as unknown as Node);
	}
	return out;
}

function linkNodeRows(raw: string, nodes: Node[]): Node[][] | null {
	const out: Node[][] = [];
	if (raw == "-") return out;
	for (const row of splitRows(raw)) {
		const linked = linkNodeList(row, nodes);
		if (linked == null) return null;
		out.push(linked);
	}
	return out;
}

export function linkTypesAndSymbols(this a: RowReader): boolean {
	const types = a.types;
	const syms = a.syms;
	const nodes = a.nodes;
	for (let i = 0; i < types.length; i += 1) {
		if (a.typeWellKnown[i] >= 0) continue;
		const t = types[i];
		const kids = a.typeChildrenIdx[i];
		const children: Type[] = [];
		for (const k of kids) {
			if (k < 0 || k >= types.length) return false;
			children.push(types[k]);
		}
		t.typeChildren = children;
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
		for (const k of a.typeOpsIdx[i]) {
			if (k >= syms.length) return false;
			t.attachedOps.push(k >= 0 ? syms[k] : null);
		}
	}

	for (let i = 0; i < syms.length; i += 1) {
		const s = syms[i];
		s.symbolType = a.symTypeIdx[i] >= 0 && a.symTypeIdx[i] < types.length ? types[a.symTypeIdx[i]] : null as unknown as Type;
		const ovls: Symbol[] = [];
		for (const k of a.symOverloadIdx[i]) {
			if (k < 0 || k >= syms.length) return false;
			ovls.push(syms[k]);
		}
		s.overloads = ovls;
		const stf: Symbol[] = [];
		for (const k of a.symStaticIdx[i]) {
			if (k < 0 || k >= syms.length) return false;
			stf.push(syms[k]);
		}
		s.staticFields = stf;
		const tps: Type[] = [];
		for (const k of a.symTypeParamsIdx[i]) {
			if (k < 0 || k >= types.length) return false;
			tps.push(types[k]);
		}
		s.typeParams = tps;
		if (a.symRetained[i]) {
			const args: Type[] = [];
			for (const k of a.symInstanceArgsIdx[i]) {
				if (k < 0 || k >= types.length) return false;
				args.push(types[k]);
			}
			const params: Type[] = [];
			for (const k of a.symInstanceParamsIdx[i]) {
				if (k < 0 || k >= types.length) return false;
				params.push(types[k]);
			}
			s.instanceArgs = args;
			s.instanceParams = params;
		}
		s.staticOwner = a.symOwnerIdx[i] >= 0 && a.symOwnerIdx[i] < syms.length ? syms[a.symOwnerIdx[i]] : null;
		s.instantiatedFrom = a.symOriginIdx[i] >= 0 && a.symOriginIdx[i] < syms.length ? syms[a.symOriginIdx[i]] : null;
		s.typeParamOwner = a.symParamOwnerIdx[i] >= 0 && a.symParamOwnerIdx[i] < syms.length ? syms[a.symParamOwnerIdx[i]] : null;
		s.declNode = a.symDeclIdx[i] >= 0 && a.symDeclIdx[i] < nodes.length ? nodes[a.symDeclIdx[i]] : null as unknown as Node;
		s.defaultParams = parseNodeArr(a.symDpRaw[i], nodes);
		const decorators = linkNodeRows(a.symFieldDecoratorsRaw[i], nodes);
		const metaValues = linkNodeList(a.symMetaValuesRaw[i], nodes);
		if (decorators == null || metaValues == null) return false;
		s.fieldDecorators = decorators;
		s.metaValues = metaValues;
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
		n.typeExprs = a.nodeTesRaw[i] == "-" ? null : parseNodeArr(a.nodeTesRaw[i], nodes);
		n.genericDefaults = a.nodeDefaultsRaw[i] == "-" ? null : parseNodeIdxList(a.nodeDefaultsRaw[i], nodes);
		n.baseExprs = a.nodeBesRaw[i] == "-" ? null : parseNodeArr(a.nodeBesRaw[i], nodes);
		n.paramLocations = a.nodePlsRaw[i] == "-" ? null : parseLocs(a.nodePlsRaw[i]);
		if (badRef(a.nodeTypeAstRef[i], nodes.length)) return false;
		n.nodeTypeAst = nd(a.nodeTypeAstRef[i], nodes);
		if (a.nodePssRaw[i] != "-") {
			const pss: Symbol[] = [];
			for (const k of parseIntsCsv(a.nodePssRaw[i])) {
				if (k < 0 || k >= syms.length) return false;
				pss.push(syms[k]);
			}
			n.paramSyms = pss;
		}
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
	assert (parseIntsCsv("4,5,6").length == 3) && parseIntsCsv("4,5,6")[2] == 6;
	assert parseIntsCsv("").length == 0;
	assert parseIntsCsv("0").length == 1 && parseIntsCsv("0")[0] == 0;
	assert parseIntsCsv("-1,-2").length == 2 && parseIntsCsv("-1,-2")[1] == -2;
	assert parseFloatsCsv("") != null && parseFloatsCsv("").length == 0;
	assert parseFloatsCsv("0").length == 1 && parseFloatsCsv("0")[0] == 0;
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
