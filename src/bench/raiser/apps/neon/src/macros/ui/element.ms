// element macro — JSX → a NeonNode: `(host, parent, before) => void`, a function
// that performs the host ops itself (docs/RENDER-MODEL.md). Nested lowercase
// elements flatten INLINE into the one mount block (D3): a single statement
// list, temps numbered across the whole tree (_r0/_r1/... elements, _t0/...
// dynamic texts, _k0/... component children, _s0/... style temps), child subtree
// emitted depth-first then appended to its parent — no per-level closure, no
// per-level call. A subtree with a static skeleton is built once and cloned per
// mount instead (D4, src/render/template.ms).
//
// Component tags, Show and For do NOT flatten: their structure changes at
// runtime, so they stay runtime calls through createComponent.

import { Node, NodeKind, DeclKind, NodeFlag, childCount, childAt, bindSym, getType, getTypeImpl, getImpl, define, expansionFile, resolveType, stringValue, intValue, isFloatLiteral, typeKind, TypeKind } from "std/meta";
import { foreignTagNames, hyphenatedAttributeNames, refusedAttributeNames } from "../../render/htmlTags";
import { isReactiveExpr, isEventName, peelHidden } from "./reactive";

function trimEdgeSpaces(s: string, fromStart: boolean, fromEnd: boolean): string {
	let lo = 0;
	let hi = s.length;
	if (fromStart) {
		while (lo < hi && s.charAt(lo) === " ") { lo = lo + 1; }
	}
	if (fromEnd) {
		while (hi > lo && s.charAt(hi - 1) === " ") { hi = hi - 1; }
	}
	return s.slice(lo, hi);
}

// JSX whitespace rule (Babel cleanJSXElementLiteralChild): a text child that
// spans lines has each line's indentation stripped and is rejoined with single
// spaces; a whitespace-only one collapses to "" and is dropped by the caller.
// Text with no newline is significant and passes through untouched.
export function cleanJsxText(raw: string): string {
	let hasNewline = false;
	let i = 0;
	while (i < raw.length) {
		const ch = raw.charAt(i);
		if (ch === "\n" || ch === "\r") { hasNewline = true; break; }
		i = i + 1;
	}
	if (!hasNewline) { return raw; }

	const lines: string[] = [];
	let cur = "";
	i = 0;
	while (i < raw.length) {
		const ch = raw.charAt(i);
		if (ch === "\n") { lines.push(cur); cur = ""; }
		else if (ch === "\t") { cur = cur + " "; }
		else if (ch !== "\r") { cur = cur + ch; }
		i = i + 1;
	}
	lines.push(cur);

	let lastNonEmpty = -1;
	i = 0;
	while (i < lines.length) {
		if (trimEdgeSpaces(lines[i], true, true) !== "") { lastNonEmpty = i; }
		i = i + 1;
	}

	let out = "";
	i = 0;
	while (i < lines.length) {
		const line = trimEdgeSpaces(lines[i], i !== 0, i !== lines.length - 1);
		if (line !== "") {
			out = i !== lastNonEmpty ? out + line + " " : out + line;
		}
		i = i + 1;
	}
	return out;
}

export macro element(node: Node): Node {
	const L = node.line;
	const C = node.column;
	const neonHostTags = ["view", "text", "textinput", "multilinetextinput", "pressable", "scrollview", "activityindicator", "switch", "image", "webview", "camera", "statusbar"];
	let htmlTable: Node | null = null;
	let htmlGlobals: Node | null = null;
	let domClasses: Node | null = null;
	function kidsOf(n: Node): Node[] {
		return n.kind === NodeKind.JSXFragment ? n.jsxFragChildren : n.jsxChildren;
	}
	function peelTypeRef(t: Node): Node {
		let cur = t;
		while (cur.kind === NodeKind.TypeGeneric) {
			const b = cur.typExprBase;
			if (b.kind !== NodeKind.Identifier) { return cur; }
			if (b.name !== "Ref" && b.name !== "Borrow" && b.name !== "Cursor" && b.name !== "Lent") { return cur; }
			if (cur.typExprArgs.length !== 1) { return cur; }
			cur = cur.typExprArgs[0];
		}
		return cur;
	}
	function isAccessorType(t: Node): boolean {
		if (t.kind !== NodeKind.TypeGeneric) { return false; }
		const b = t.typExprBase;
		return b.kind === NodeKind.Identifier && b.name === "Accessor";
	}
	function unionHasNull(t: Node): boolean {
		if (t.kind !== NodeKind.TypeUnion) { return false; }
		for (const m of t.typExprMembers) {
			if (m.kind === NodeKind.Identifier && m.name === "null") { return true; }
		}
		return false;
	}
	function clonePath(e: Node): Node | null {
		const p = peelHidden(e);
		if (p.kind === NodeKind.Identifier) {
			return { kind: NodeKind.Identifier, line: p.line, column: p.column, name: p.name };
		}
		if (p.kind === NodeKind.MemberExpr) {
			const base = clonePath(p.object);
			if (base === null) { return null; }
			return { kind: NodeKind.MemberExpr, line: p.line, column: p.column, object: base as Node, property: p.property, isOptional: false };
		}
		return null;
	}
	function expandAttrs(list: Node[]): Node[] {
		let names: string[] = [];
		let out: Node[] = [];
		for (const a of list) {
			if (a.kind === NodeKind.JSXAttribute) {
				let at = -1;
				for (let i = 0; i < names.length; i = i + 1) { if (names[i] === a.jsxAttrName) { at = i; } }
				if (at >= 0) { out[at] = a; } else { names.push(a.jsxAttrName); out.push(a); }
				continue;
			}
			if (a.kind !== NodeKind.JSXSpreadAttribute) { continue; }
			const arg = a.jsxSpreadArg;
			const argType = arg.nodeType;
			if (argType === null) {
				error("a spread needs a typed object: annotate the value being spread", a as Node);
				continue;
			}
			const t = objectType(argType);
			if (t === null || t.typExprFieldNames.length === 0) {
				error("a spread needs an object type with named fields — a map or an index signature has no names to read at compile time", a as Node);
				continue;
			}
			if (clonePath(arg) === null) {
				error("a spread needs a variable or a field, not an expression: it is read once per prop", a as Node);
				continue;
			}
			for (let i = 0; i < t.typExprFieldNames.length; i = i + 1) {
				const fname = t.typExprFieldNames[i];
				const ftype = t.typExprFieldTypes[i];
				if (fname === "children") {
					error("children cannot come from a spread: pass it as a child of the element", a as Node);
					continue;
				}
				const isEvent = isEventName(fname);
				if (isEvent && unionHasNull(ftype)) {
					error("a nullable " + fname + " handler is not supported yet: give the prop a non-null handler", a as Node);
					continue;
				}
				if (fname === "style" && unionHasNull(ftype)) {
					error("a nullable style is not supported yet: pass an empty style instead of null", a as Node);
					continue;
				}
				let value: Node = {
					kind: NodeKind.MemberExpr, line: a.line, column: a.column,
					object: clonePath(arg) as Node, property: fname, isOptional: false,
				};
				if (isAccessorType(ftype)) {
					value = { kind: NodeKind.CallExpr, line: a.line, column: a.column, callee: value, arguments: [] };
				}
				const attrNode: Node = {
					kind: NodeKind.JSXAttribute, line: a.line, column: a.column,
					jsxAttrName: fname, jsxAttrValue: value,
				};
				let at = -1;
				for (let j = 0; j < names.length; j = j + 1) { if (names[j] === fname) { at = j; } }
				if (at >= 0) { out[at] = attrNode; } else { names.push(fname); out.push(attrNode); }
			}
		}
		return out;
	}
	function loadHtmlTable(at: Node): boolean {
		if (htmlTable === null) {
			htmlTable = objectType(resolveType("HtmlElements"));
			htmlGlobals = objectType(resolveType("HtmlGlobalAttributes"));
		}
		if (htmlTable === null || htmlGlobals === null) {
			error("<" + at.jsxTag + "> is checked against the HTML tag table, which is not in scope: name neon's src/converters in build.ms globalImports", at);
			return false;
		}
		return true;
	}
	function fieldType(obj: Node, name: string): Node | null {
		for (let i = 0; i < obj.typExprFieldNames.length; i = i + 1) {
			if (obj.typExprFieldNames[i] === name) { return obj.typExprFieldTypes[i]; }
		}
		return null;
	}
	function editDistance(a: string, b: string): number {
		let before: number[] = [];
		let prev: number[] = [];
		for (let j = 0; j <= b.length; j = j + 1) { prev.push(j); }
		for (let i = 1; i <= a.length; i = i + 1) {
			let cur: number[] = [i];
			for (let j = 1; j <= b.length; j = j + 1) {
				let best = prev[j] + 1;
				if (cur[j - 1] + 1 < best) { best = cur[j - 1] + 1; }
				const change = prev[j - 1] + (a.charAt(i - 1) === b.charAt(j - 1) ? 0 : 1);
				if (change < best) { best = change; }
				if (i > 1 && j > 1 && a.charAt(i - 1) === b.charAt(j - 2) && a.charAt(i - 2) === b.charAt(j - 1) && before[j - 2] + 1 < best) {
					best = before[j - 2] + 1;
				}
				cur.push(best);
			}
			before = prev;
			prev = cur;
		}
		return prev[b.length];
	}
	function nearestName(name: string, names: string[]): string {
		let best = "";
		let bestDistance: number = name.length < 5 ? 2 : 3;
		for (const c of names) {
			const d = editDistance(name.toLowerCase(), c.toLowerCase());
			if (d < bestDistance) { best = c; bestDistance = d; }
		}
		return best;
	}
	function typeText(t: Node): string {
		const p = peelTypeRef(t);
		if (p.kind === NodeKind.Identifier) { return p.name; }
		if (p.kind === NodeKind.StringLiteral) { return "\"" + stringValue(p) + "\""; }
		if (p.kind === NodeKind.TypeUnion) {
			let parts: string[] = [];
			for (const m of p.typExprMembers) { parts.push(typeText(m)); }
			return parts.join(" | ");
		}
		if (isAccessorType(p)) { return "Accessor<" + typeText(p.typExprArgs[0]) + ">"; }
		return "a non-attribute type";
	}
	function attributeKinds(t: Node, into: string[], depth: number): void {
		const p = peelTypeRef(t);
		if (p.kind === NodeKind.TypeUnion) {
			for (const m of p.typExprMembers) { attributeKinds(m, into, depth); }
			return;
		}
		if (isAccessorType(p)) { attributeKinds(p.typExprArgs[0], into, depth); return; }
		if (p.kind === NodeKind.StringLiteral) { into.push("lit:" + stringValue(p)); return; }
		if (p.kind === NodeKind.BooleanLiteral) { into.push("boolean"); return; }
		if (p.kind === NodeKind.NumberLiteral) { into.push("number"); return; }
		if (p.kind === NodeKind.Identifier) {
			const n = p.name;
			if (n === "string" || n === "null" || n === "boolean" || n === "number") { into.push(n); return; }
			if (n === "true" || n === "false") { into.push("boolean"); return; }
			if (n === "float32" || n === "float64" || n === "int8" || n === "int16" || n === "int32" || n === "int64"
				|| n === "uint8" || n === "uint16" || n === "uint32" || n === "uint64") { into.push("number"); return; }
			const impl = getTypeImpl(p);
			if (depth < 8 && impl !== null && !((impl as Node).kind === NodeKind.Identifier && (impl as Node).name === n)) {
				attributeKinds(impl as Node, into, depth + 1);
				return;
			}
		}
		into.push("other");
	}
	function takesKind(expected: string[], kind: string): boolean {
		if (kind.startsWith("lit:")) { return expected.includes("string") || expected.includes(kind); }
		return expected.includes(kind);
	}
	function choose(cond: Node, yes: Node, no: Node): Node {
		return { kind: NodeKind.ConditionalExpr, line: cond.line, column: cond.column, ternaryCondition: cond, ternaryConsequent: yes, ternaryAlternate: no };
	}
	function htmlAttribute(tag: string, own: Node | null, a: Node): Node | null {
		const name = a.jsxAttrName;
		if (isEventName(name) || name === "ref" || name === "style") { return a; }
		if (name.startsWith("data-") || name.startsWith("aria-")) { return a; }
		let expectedType: Node | null = own === null ? null : fieldType(own as Node, name);
		if (expectedType === null && refusedAttributeNames().includes(tag + "." + name)) {
			error("<" + tag + "> does not take the attribute '" + name + "'", a);
			return null;
		}
		if (expectedType === null) { expectedType = fieldType(htmlGlobals as Node, name); }
		if (expectedType === null && name.includes("-") && hyphenatedAttributeNames().includes(name)) { return a; }
		if (expectedType === null) {
			let names: string[] = [];
			if (own !== null) { for (const f of (own as Node).typExprFieldNames) { names.push(f); } }
			for (const f of (htmlGlobals as Node).typExprFieldNames) { names.push(f); }
			const near = nearestName(name, names);
			error("<" + tag + "> has no attribute '" + name + "'" + (near === "" ? "." : ": did you mean '" + near + "'?") + " Custom data goes in a data-* attribute", a);
			return null;
		}
		let expected: string[] = [];
		attributeKinds(expectedType as Node, expected, 0);
		const value = a.jsxAttrValue;
		const enumerated = expected.includes("lit:true");
		const at = (v: Node): Node => ({ kind: NodeKind.JSXAttribute, line: a.line, column: a.column, jsxAttrName: name, jsxAttrValue: v });
		if (value.kind === NodeKind.BooleanLiteral) {
			if (!expected.includes("boolean")) {
				error("<" + tag + "> attribute '" + name + "' takes " + typeText(expectedType as Node) + ", so it needs a value", a);
				return null;
			}
			if (enumerated) { return at(strLit(value.boolValue ? "true" : "false", a.line, a.column)); }
			return value.boolValue ? at(strLit("", a.line, a.column)) : null;
		}
		if (value.kind === NodeKind.StringLiteral) {
			if (takesKind(expected, "lit:" + stringValue(value))) { return a; }
			error("<" + tag + "> attribute '" + name + "' takes " + typeText(expectedType as Node) + ", not \"" + stringValue(value) + "\"", a);
			return null;
		}
		const valueType = peelHidden(value).nodeType;
		if (valueType === null) { return a; }
		let given: string[] = [];
		attributeKinds(valueType as Node, given, 0);
		let lowered = "";
		let nullable = false;
		for (const k of given) {
			if (k === "null") { nullable = true; continue; }
			if (!takesKind(expected, k)) {
				error("<" + tag + "> attribute '" + name + "' takes " + typeText(expectedType as Node) + ", not " + typeText(valueType as Node), a);
				return null;
			}
			const lowering = k === "number" || k === "boolean" ? k : "string";
			if (lowered !== "" && lowered !== lowering) {
				error("<" + tag + "> attribute '" + name + "' needs a value of one type, not " + typeText(valueType as Node) + ": convert it to a string first", a);
				return null;
			}
			lowered = lowering;
		}
		if (lowered === "string" || lowered === "") { return a; }
		if (lowered === "number" && value.kind === NodeKind.NumberLiteral && !isFloatLiteral(value)) {
			return at(strLit(intValue(value).toString(), a.line, a.column));
		}
		const accessorRead = isAccessorTyped(value);
		const readOf = (v: Node): Node => accessorRead ? { kind: NodeKind.CallExpr, line: a.line, column: a.column, callee: v, arguments: [] } : v;
		const noValue: Node = { kind: NodeKind.NullLiteral, line: a.line, column: a.column };
		const lower = (v: Node): Node => {
			if (lowered === "number") { return { kind: NodeKind.BinaryExpr, line: a.line, column: a.column, operator: "+", left: strLit("", a.line, a.column), right: v }; }
			if (enumerated) { return choose(v, strLit("true", a.line, a.column), strLit("false", a.line, a.column)); }
			return choose(v, strLit("", a.line, a.column), noValue);
		};
		if (!nullable) { return at(lower(readOf(value))); }
		const payload = accessorRead ? peelTypeRef(valueType as Node).typExprArgs[0] : (valueType as Node);
		const held = ident("__msAttr", a.line, a.column);
		const absent: Node = { kind: NodeKind.BinaryExpr, line: a.line, column: a.column, operator: "===", left: held, right: { kind: NodeKind.NullLiteral, line: a.line, column: a.column } };
		const pick: Node = {
			kind: NodeKind.ArrowFunction, line: a.line, column: a.column,
			arrowParams: ["__msAttr"], arrowParamTypes: [typeText(payload)], arrowFlags: "", arrowReturnType: "string | null",
			arrowBody: choose(absent, noValue, lower(ident("__msAttr", a.line, a.column))),
		};
		return at({ kind: NodeKind.CallExpr, line: a.line, column: a.column, callee: pick, arguments: [readOf(value)] });
	}
	function checkHtmlElement(el: Node, attrs: Node[]): Node[] {
		const tag = el.jsxTag;
		if (tag.includes("-") || neonHostTags.includes(tag) || !loadHtmlTable(el)) { return attrs; }
		const ownType = fieldType(htmlTable as Node, tag);
		if (ownType === null) {
			if (foreignTagNames().includes(tag)) { return attrs; }
			const near = nearestName(tag, (htmlTable as Node).typExprFieldNames);
			error("<" + tag + "> is not an HTML element" + (near === "" ? "." : ": did you mean <" + near + ">?") + " A custom element needs a '-' in its name", el);
			return attrs;
		}
		const own = objectType(ownType);
		let out: Node[] = [];
		for (const a of attrs) {
			const kept = a.kind === NodeKind.JSXAttribute ? htmlAttribute(tag, own === htmlGlobals ? null : own, a) : a;
			if (kept !== null) { out.push(kept as Node); }
		}
		return out;
	}
	function flattenFragments(n: Node): Node {
		let out: Node[] = [];
		for (const c of kidsOf(n)) {
			if (c.kind === NodeKind.JSXFragment) {
				for (const g of kidsOf(flattenFragments(c))) { out.push(g); }
			} else if (c.kind === NodeKind.JSXElement) {
				out.push(flattenFragments(c));
			} else {
				out.push(c);
			}
		}
		if (n.kind === NodeKind.JSXFragment) {
			return { kind: NodeKind.JSXFragment, line: n.line, column: n.column, jsxFragChildren: out };
		}
		const first = n.jsxTag.charAt(0);
		const attrs = expandAttrs(n.jsxAttrs);
		return { kind: NodeKind.JSXElement, line: n.line, column: n.column, jsxTag: n.jsxTag, jsxAttrs: first >= "a" && first <= "z" ? checkHtmlElement(n, attrs) : attrs, jsxChildren: out, jsxSelfClosing: n.jsxSelfClosing };
	}
	function isAccessorTyped(n: Node): boolean {
		const t = peelHidden(n).nodeType;
		if (t !== null && t.kind === NodeKind.TypeGeneric) {
			const base = t.typExprBase;
			return base.kind === NodeKind.Identifier && base.name === "Accessor";
		}
		return false;
	}
	function accessorSlot(t: Node): number {
		if (isAccessorType(t)) { return 1; }
		if (t.kind !== NodeKind.TypeUnion) { return 0; }
		let reactive = false;
		let other = false;
		for (const m of t.typExprMembers) {
			if (isAccessorType(m)) {
				reactive = true;
			} else if (!(m.kind === NodeKind.Identifier && m.name === "null")) {
				other = true;
			}
		}
		if (!reactive) { return 0; }
		return other ? -1 : 1;
	}
	function objectType(t: Node | null): Node | null {
		if (t === null) { return null; }
		const direct = peelTypeRef(t as Node);
		if (direct.kind === NodeKind.TypeObject) { return direct; }
		const impl = getTypeImpl(direct);
		if (impl === null) { return null; }
		const expanded = peelTypeRef(impl as Node);
		return expanded.kind === NodeKind.TypeObject ? expanded : null;
	}
	// WORKAROUND.md N2.
	function staticFieldType(sym: Node, name: string): Node | null {
		const impl = getImpl(sym);
		if (impl === null || (impl as Node).kind !== NodeKind.ClassDecl) { return null; }
		for (const m of (impl as Node).classBody) {
			if (m.kind !== NodeKind.PropertyDecl || !m.propIsStatic || m.propName !== name) { continue; }
			if (m.propInitializer !== null) { return m.propInitializer.nodeType; }
		}
		return null;
	}
	function tagType(c: Node): Node | null {
		const parts: string[] = c.jsxTag.split(".");
		const sym = bindSym(parts[0]);
		if (sym === null) {
			error("<" + c.jsxTag + "> is not a component in scope", c);
			return null;
		}
		let t: Node | null = getType(sym);
		for (let i = 1; i < parts.length; i = i + 1) {
			const holder = objectType(t);
			t = null;
			if (holder !== null) {
				for (let j = 0; j < holder.typExprFieldNames.length; j = j + 1) {
					if (holder.typExprFieldNames[j] === parts[i]) { t = holder.typExprFieldTypes[j]; }
				}
			}
			if (t === null && i === 1) { t = staticFieldType(sym as Node, parts[i]); }
			if (t === null) {
				error("<" + c.jsxTag + "> names no field '" + parts[i] + "'", c);
				return null;
			}
		}
		return t;
	}
	function isContextTag(c: Node): boolean {
		const t = tagType(c);
		if (t === null) { return false; }
		const generic = peelTypeRef(t as Node);
		if (generic.kind !== NodeKind.TypeGeneric) { return false; }
		const base = generic.typExprBase;
		return base.kind === NodeKind.Identifier && base.name === "Context";
	}
	function componentType(c: Node): Node | null {
		const t = tagType(c);
		const fn = t === null ? null : peelTypeRef(t as Node);
		if (fn === null || fn.kind !== NodeKind.TypeFunction) {
			error("<" + c.jsxTag + "> is not a component: its type is not a function", c);
			return null;
		}
		return fn;
	}
	function declaredProps(c: Node): Node | null {
		const fn = componentType(c);
		if (fn === null) { return null; }
		if (fn.typExprParams.length === 0) {
			return { kind: NodeKind.TypeObject, line: c.line, column: c.column, typExprFieldNames: [], typExprFieldTypes: [] };
		}
		const props = objectType(fn.typExprParams[0]);
		if (props === null) {
			error("<" + c.jsxTag + "> takes props of a type the element macro cannot read field by field", c);
		}
		return props;
	}
	function isNumberTyped(n: Node): boolean {
		const t = peelHidden(n).nodeType;
		if (t === null) { return false; }
		let payload: Node = t as Node;
		if (payload.kind === NodeKind.TypeGeneric && payload.typExprArgs.length === 1) {
			const base = payload.typExprBase;
			if (base.kind === NodeKind.Identifier && base.name === "Accessor") { payload = payload.typExprArgs[0]; }
		}
		if (payload.kind !== NodeKind.Identifier) { return false; }
		const name = payload.name;
		return name === "number" || name === "float32" || name === "float64"
			|| name === "int8" || name === "int16" || name === "int32" || name === "int64"
			|| name === "uint8" || name === "uint16" || name === "uint32" || name === "uint64";
	}
	function asText(n: Node): Node {
		if (!isNumberTyped(n)) { return n; }
		return {
			kind: NodeKind.CallExpr, line: n.line, column: n.column,
			callee: { kind: NodeKind.MemberExpr, line: n.line, column: n.column, object: n, property: "toString", isOptional: false },
			arguments: [],
		};
	}
	function hostCall(recv: string, method: string, args: Node[], ln: int32, col: int32): Node {
		return {
			kind: NodeKind.CallExpr, line: ln, column: col,
			callee: { kind: NodeKind.MemberExpr, line: ln, column: col, object: { kind: NodeKind.Identifier, line: ln, column: col, name: recv }, property: method, isOptional: false },
			arguments: args,
		};
	}

	function ident(n: string, ln: int32, col: int32): Node {
		return { kind: NodeKind.Identifier, line: ln, column: col, name: n };
	}

	function strLit(v: string, ln: int32, col: int32): Node {
		return { kind: NodeKind.StringLiteral, line: ln, column: col, value: v };
	}

	let errNodes: Node[] = [];
	let errMsgs: string[] = [];
	let componentHome = "";
	let optIdx = 0;
	function presentKind(n: Node): string {
		const t = peelHidden(n).nodeType;
		if (t === null || t.kind !== NodeKind.TypeUnion) { return ""; }
		let hasNull = false;
		let kind = "value";
		for (const m of t.typExprMembers) {
			if (m.kind === NodeKind.Identifier && m.name === "null") { hasNull = true; }
			if (m.kind === NodeKind.TypeGeneric) {
				const base = m.typExprBase;
				if (base.kind === NodeKind.Identifier && base.name === "Accessor") { kind = "accessor"; }
			}
		}
		return hasNull ? kind : "";
	}
	function pushIfPresent(into: Node[], name: string, value: Node, then: Node, otherwise: Node[], ln: int32, col: int32): void {
		into.push({
			kind: NodeKind.VariableDecl, line: ln, column: col,
			declName: name, declType: "", declKind: DeclKind.Const,
			initializer: value,
		});
		into.push({
			kind: NodeKind.IfStmt, line: ln, column: col,
			condition: {
				kind: NodeKind.BinaryExpr, line: ln, column: col, operator: "!==",
				left: { kind: NodeKind.Identifier, line: ln, column: col, name: name },
				right: { kind: NodeKind.NullLiteral, line: ln, column: col },
			},
			consequent: {
				kind: NodeKind.BlockStmt, line: ln, column: col,
				statements: [{ kind: NodeKind.ExprStmt, line: ln, column: col, expr: then }],
			},
			alternate: { kind: NodeKind.BlockStmt, line: ln, column: col, statements: otherwise },
		});
	}
	function pushWhenPresent(into: Node[], callee: Node, lead: Node[], value: Node, otherwise: Node[], ln: int32, col: int32): void {
		const name = "_o" + optIdx.toString();
		optIdx = optIdx + 1;
		const args: Node[] = [];
		for (const l of lead) { args.push(l); }
		args.push({ kind: NodeKind.Identifier, line: ln, column: col, name: name });
		pushIfPresent(into, name, value, { kind: NodeKind.CallExpr, line: ln, column: col, callee: callee, arguments: args }, otherwise, ln, col);
	}
	function flattenRefs(v: Node, into: Node[]): void {
		if (v.kind === NodeKind.ArrayLiteral) {
			for (const e of v.elements) { flattenRefs(e, into); }
		} else if (v.kind !== NodeKind.NullLiteral) {
			into.push(v);
		}
	}
	function setupRefCall(inner: Node): Node {
		return {
			kind: NodeKind.CallExpr, line: inner.line, column: inner.column,
			callee: ident("setupRef", inner.line, inner.column),
			arguments: [{
				kind: NodeKind.ArrowFunction, line: inner.line, column: inner.column,
				arrowParams: [], arrowParamTypes: [], arrowFlags: "", arrowReturnType: "",
				arrowBody: inner,
			}],
		};
	}
	// A ref array is composed at compile time (nested arrays and null entries
	// flatten away); a call is a directive factory, so its setup runs here, in the
	// current owner and untracked, while the function it returns is the apply phase.
	function refSource(v: Node): Node {
		if (v.kind === NodeKind.ArrayLiteral) {
			let fns: Node[] = [];
			flattenRefs(v, fns);
			if (fns.length === 0) {
				errNodes.push(v);
				errMsgs.push("a ref array needs at least one ref: ref={[a, b]}");
				return v;
			}
			return setupRefCall({
				kind: NodeKind.CallExpr, line: v.line, column: v.column,
				callee: ident("composeRefs", v.line, v.column),
				arguments: [{ kind: NodeKind.ArrayLiteral, line: v.line, column: v.column, elements: fns }],
			});
		}
		if (v.kind === NodeKind.CallExpr) { return setupRefCall(v); }
		return v;
	}
	function refElementClass(tag: string, v: Node): string {
		if (define("js") !== "true" || v.kind === NodeKind.ArrayLiteral || v.kind === NodeKind.CallExpr) { return ""; }
		if (domClasses === null) { domClasses = objectType(resolveType("HTMLElementTagNameMap")); }
		if (domClasses === null) { return ""; }
		const cls = fieldType(domClasses as Node, tag);
		const fnType = peelHidden(v).nodeType;
		if (cls === null || fnType === null) { return ""; }
		let fn: Node = fnType as Node;
		if (fn.kind === NodeKind.TypeUnion) {
			for (const m of fn.typExprMembers) {
				if (m.kind === NodeKind.TypeFunction) { fn = m; }
			}
		}
		if (fn.kind !== NodeKind.TypeFunction || fn.typExprParams.length === 0) { return ""; }
		const param = peelTypeRef(fn.typExprParams[0]);
		if (typeKind(param) === TypeKind.Unknown) { return ""; }
		return typeText(cls as Node);
	}
	function pushRef(into: Node[], tag: string, elVar: string, v: Node, ln: int32, col: int32): void {
		const cls = refElementClass(tag, v);
		if (cls !== "" && define("server") !== "") { return; }
		const target: Node = cls === "" ? ident(elVar, ln, col) : { kind: NodeKind.TypeAssertion, line: ln, column: col, asExpr: ident(elVar, ln, col), asType: cls };
		const source = refSource(v);
		if (v.kind !== NodeKind.ArrayLiteral && presentKind(v) !== "") {
			pushWhenPresent(into, ident("applyRef", ln, col), [target], source, [], ln, col);
		} else {
			into.push({
				kind: NodeKind.ExprStmt, line: ln, column: col,
				expr: {
					kind: NodeKind.CallExpr, line: ln, column: col,
					callee: ident("applyRef", ln, col),
					arguments: [target, source],
				},
			});
		}
	}
	function pushAttrWhenPresent(into: Node[], elName: string, attrName: string, value: Node, otherwise: Node[], ln: int32, col: int32): void {
		const name = "_o" + optIdx.toString();
		optIdx = optIdx + 1;
		const read: Node = {
			kind: NodeKind.CallExpr, line: ln, column: col,
			callee: { kind: NodeKind.TypeAssertion, line: ln, column: col, asExpr: { kind: NodeKind.Identifier, line: ln, column: col, name: name }, asType: "() => string" },
			arguments: [],
		};
		const bind: Node = {
			kind: NodeKind.CallExpr, line: ln, column: col,
			callee: { kind: NodeKind.Identifier, line: ln, column: col, name: "bindAttr" },
			arguments: [
				{ kind: NodeKind.Identifier, line: ln, column: col, name: "host" },
				{ kind: NodeKind.Identifier, line: ln, column: col, name: elName },
				{ kind: NodeKind.StringLiteral, line: ln, column: col, value: attrName },
				{ kind: NodeKind.ArrowFunction, line: ln, column: col, arrowParams: [], arrowParamTypes: [], arrowFlags: "", arrowReturnType: "", arrowBody: read },
			],
		};
		pushIfPresent(into, name, value, bind, otherwise, ln, col);
	}
	const optChangeTextMsg = "a nullable onChangeText handler is not supported yet — pass a handler that is always present";
	function pushStyleConst(into: Node[], init: Node, nodeVar: string, tempName: string, ln: int32, col: int32): void {
		into.push({
			kind: NodeKind.VariableDecl, line: ln, column: col,
			declName: tempName, declType: "Style", declKind: DeclKind.Const,
			initializer: init,
		});
		into.push({
			kind: NodeKind.ExprStmt, line: ln, column: col,
			expr: {
				kind: NodeKind.CallExpr, line: ln, column: col,
				callee: { kind: NodeKind.MemberExpr, line: ln, column: col, object: { kind: NodeKind.Identifier, line: ln, column: col, name: "host" }, property: "setStyle", isOptional: false },
				arguments: [
					{ kind: NodeKind.Identifier, line: ln, column: col, name: nodeVar },
					{ kind: NodeKind.Identifier, line: ln, column: col, name: tempName },
				],
			},
		});
	}
	function pushStyleLayers(into: Node[], sv: Node, nodeVar: string, tempName: string, ln: int32, col: int32): void {
		if (sv.elements.length === 0) {
			errNodes.push(sv);
			errMsgs.push("a style layer array needs at least one layer: style={[base, override]}");
			return;
		}
		let allStatic = true;
		let reactive = false;
		const read: Node[] = [];
		for (const layer of sv.elements) {
			if (layer.kind !== NodeKind.ObjectLiteral) {
				if (isAccessorTyped(layer)) {
					reactive = true;
					read.push({ kind: NodeKind.CallExpr, line: layer.line, column: layer.column, callee: layer, arguments: [] });
				} else {
					if (isReactiveExpr(layer)) { reactive = true; }
					read.push(layer);
				}
				allStatic = false;
				continue;
			}
			const fields: Node[] = [];
			for (let i = 0; i < layer.keys.length; i = i + 1) {
				const fv = layer.properties[i];
				if (isAccessorTyped(fv)) {
					reactive = true;
					fields.push({ kind: NodeKind.CallExpr, line: fv.line, column: fv.column, callee: fv, arguments: [] });
				} else {
					if (isReactiveExpr(fv)) { reactive = true; }
					fields.push(fv);
				}
			}
			read.push({ kind: NodeKind.ObjectLiteral, line: layer.line, column: layer.column, properties: fields, keys: layer.keys });
		}
		if (reactive) {
			into.push({
				kind: NodeKind.ExprStmt, line: ln, column: col,
				expr: {
					kind: NodeKind.CallExpr, line: ln, column: col,
					callee: { kind: NodeKind.Identifier, line: ln, column: col, name: "bindStyleAll" },
					arguments: [
						{ kind: NodeKind.Identifier, line: ln, column: col, name: "host" },
						{ kind: NodeKind.Identifier, line: ln, column: col, name: nodeVar },
						{
							kind: NodeKind.ArrowFunction, line: ln, column: col,
							arrowParams: [], arrowParamTypes: [], arrowFlags: "", arrowReturnType: "",
							arrowBody: {
								kind: NodeKind.CallExpr, line: ln, column: col,
								callee: { kind: NodeKind.Identifier, line: ln, column: col, name: "layerStyles" },
								arguments: [{ kind: NodeKind.ArrayLiteral, line: sv.line, column: sv.column, elements: read }],
							},
						},
					],
				},
			});
			return;
		}
		if (!allStatic) {
			into.push({
				kind: NodeKind.ExprStmt, line: ln, column: col,
				expr: {
					kind: NodeKind.CallExpr, line: ln, column: col,
					callee: ident("applyStaticStyle", ln, col),
					arguments: [
						ident("host", ln, col),
						ident(nodeVar, ln, col),
						{
							kind: NodeKind.CallExpr, line: ln, column: col,
							callee: ident("layerStyles", ln, col),
							arguments: [sv],
						},
					],
				},
			});
			return;
		}
		const mergedKeys: string[] = [];
		const mergedValues: Node[] = [];
		for (const layer of sv.elements) {
			for (let i = 0; i < layer.keys.length; i = i + 1) {
				const fv = layer.properties[i];
				if (fv.kind === NodeKind.NullLiteral) { continue; }
				const k = layer.keys[i];
				let at = -1;
				for (let j = 0; j < mergedKeys.length; j = j + 1) {
					if (mergedKeys[j] === k) { at = j; }
				}
				if (at >= 0) { mergedValues[at] = fv; } else { mergedKeys.push(k); mergedValues.push(fv); }
			}
		}
		pushStyleConst(into, { kind: NodeKind.ObjectLiteral, line: ln, column: col, properties: mergedValues, keys: mergedKeys }, nodeVar, tempName, ln, col);
	}
	function pushStyleObject(into: Node[], sv: Node, nodeVar: string, tempName: string, ln: int32, col: int32): void {
		const staticKeys: string[] = [];
		const staticProps: Node[] = [];
		const dynNames: string[] = [];
		const dynExprs: Node[] = [];
		for (let i = 0; i < sv.keys.length; i = i + 1) {
			const fv = sv.properties[i];
			if (isReactiveExpr(fv) || isAccessorTyped(fv)) {
				dynNames.push(sv.keys[i]);
				dynExprs.push(fv);
			} else {
				staticKeys.push(sv.keys[i]);
				staticProps.push(fv);
			}
		}
		pushStyleConst(into, staticKeys.length > 0
			? { kind: NodeKind.ObjectLiteral, line: ln, column: col, properties: staticProps, keys: staticKeys }
			: { kind: NodeKind.CallExpr, line: ln, column: col, callee: { kind: NodeKind.Identifier, line: ln, column: col, name: "emptyStyle" }, arguments: [] },
			nodeVar, tempName, ln, col);
		for (let i = 0; i < dynNames.length; i = i + 1) {
			into.push({
				kind: NodeKind.ExprStmt, line: ln, column: col,
				expr: {
					kind: NodeKind.CallExpr, line: ln, column: col,
					callee: { kind: NodeKind.Identifier, line: ln, column: col, name: "bindStyleProp" },
					arguments: [
						{ kind: NodeKind.Identifier, line: ln, column: col, name: "host" },
						{ kind: NodeKind.Identifier, line: ln, column: col, name: nodeVar },
						{ kind: NodeKind.Identifier, line: ln, column: col, name: tempName },
						{ kind: NodeKind.StringLiteral, line: ln, column: col, value: dynNames[i] },
						{
							kind: NodeKind.ArrowFunction, line: ln, column: col,
							arrowParams: [], arrowParamTypes: [], arrowFlags: "", arrowReturnType: "",
							arrowBody: dynExprs[i],
						},
					],
				},
			});
		}
	}
	function isNodeType(t: Node): boolean {
		if (t.kind !== NodeKind.TypeFunction || t.typExprParams.length !== 3) { return false; }
		const names = t.typExprParamNames;
		return names.length === 3 && names[0] === "host" && names[1] === "parent" && names[2] === "before";
	}
	function nodeSlot(t: Node): boolean {
		const direct = peelTypeRef(t);
		if (isNodeType(direct)) { return true; }
		if (direct.kind !== NodeKind.TypeUnion) { return false; }
		let hasNode = false;
		for (const member of direct.typExprMembers) {
			if (isNodeType(peelTypeRef(member))) { hasNode = true; }
			else if (!(member.kind === NodeKind.Identifier && member.name === "null")) { return false; }
		}
		return hasNode;
	}
	function componentWithProps(value: Node, fn: Node): Node {
		if (fn.typExprParams.length !== 0) { return value; }
		return {
			kind: NodeKind.ArrowFunction, line: value.line, column: value.column,
			arrowParams: ["__slotProps"], arrowParamTypes: ["{}"], arrowFlags: "", arrowReturnType: "NeonNode",
			arrowBody: {
				kind: NodeKind.CallExpr, line: value.line, column: value.column,
				callee: value, arguments: [],
			},
		};
	}
	function lowerNodeSlot(value: Node): Node {
		const source = peelHidden(value);
		if (isJsx(source)) {
			return {
				kind: NodeKind.MacroInvocation, line: value.line, column: value.column,
				macroName: "element", macroArgs: [source],
			};
		}
		const metadata = source.nodeType;
		if (metadata === null) { return value; }
		const fn = peelTypeRef(metadata as Node);
		if (fn.kind !== NodeKind.TypeFunction || isNodeType(fn)) { return value; }
		if (!isNodeType(peelTypeRef(fn.typExprReturn))) { return value; }
		for (let i = 1; i < fn.typExprParams.length; i = i + 1) {
			if (!unionHasNull(peelTypeRef(fn.typExprParams[i]))) {
				error("a node slot component requires another parameter: pass an element with props instead", value);
				return value;
			}
		}
		if (fn.typExprParams.length > 0) {
			const props = objectType(fn.typExprParams[0]);
			if (props === null) {
				error("a node slot component needs object props the macro can inspect: pass an element with props instead", value);
				return value;
			}
			for (let i = 0; i < props.typExprFieldNames.length; i = i + 1) {
				if (!unionHasNull(peelTypeRef(props.typExprFieldTypes[i]))) {
					error("a node slot component requires prop '" + props.typExprFieldNames[i] + "': pass an element with props instead", value);
					return value;
				}
			}
		}
		return {
			kind: NodeKind.CallExpr, line: value.line, column: value.column,
			callee: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "createComponent" },
			arguments: [
				componentWithProps(value, fn),
				{ kind: NodeKind.ObjectLiteral, line: value.line, column: value.column, keys: [], properties: [] },
			],
		};
	}
	function isNodeArrayTyped(n: Node): boolean {
		const t = peelHidden(n).nodeType;
		if (t === null) { return false; }
		if (t.kind === NodeKind.TypeArray) { return isNodeType(t.typExprElement); }
		if (t.kind !== NodeKind.TypeGeneric || t.typExprArgs.length !== 1) { return false; }
		const arg = t.typExprArgs[0];
		if (arg.kind === NodeKind.TypeArray) { return isNodeType(arg.typExprElement); }
		return false;
	}
	function isNodeTyped(n: Node): boolean {
		const t = peelHidden(n).nodeType;
		return t !== null && isNodeType(t as Node);
	}
	function isNullableNodeTyped(n: Node): boolean {
		const t = peelHidden(n).nodeType;
		if (t === null || t.kind !== NodeKind.TypeUnion) { return false; }
		let hasNull = false;
		let hasNode = false;
		for (const m of t.typExprMembers) {
			if (m.kind === NodeKind.Identifier && m.name === "null") { hasNull = true; }
			else if (isNodeType(m)) { hasNode = true; }
			else { return false; }
		}
		return hasNull && hasNode;
	}
	function isNodeValued(n: Node): boolean {
		return isNodeTyped(n) || isNodeArrayTyped(n) || isNullableNodeTyped(n);
	}
	function declaredCount(names: string[]): int32 {
		let k = 0;
		for (const p of names) {
			if (!p.startsWith("__msPad")) { k = k + 1; }
		}
		return k;
	}
	function rowArity(n: Node): int32 {
		if (n.kind === NodeKind.ArrowFunction) { return declaredCount(n.arrowParams); }
		if (n.kind === NodeKind.FunctionExpr) { return declaredCount(n.funcExprParams); }
		const t = peelHidden(n).nodeType;
		if (t !== null && t.kind === NodeKind.TypeFunction) { return t.typExprParams.length; }
		return 0;
	}
	function readsName(n: Node, name: string): boolean {
		if (n.kind === NodeKind.Identifier && n.name === name) { return true; }
		const c = childCount(n);
		for (let i = 0; i < c; i = i + 1) {
			if (readsName(childAt(n, i), name)) { return true; }
		}
		return false;
	}
	function rowUsesIndex(row: Node): boolean {
		const r = peelHidden(row);
		if (r.kind !== NodeKind.ArrowFunction) { return true; }
		let declared: string[] = [];
		for (const p of r.arrowParams) {
			if (!p.startsWith("__msPad")) { declared.push(p); }
		}
		if (declared.length < 2) { return false; }
		return readsName(r.arrowBody, declared[1]);
	}
	function isFunctionValued(n: Node): boolean {
		if (n.kind === NodeKind.ArrowFunction || n.kind === NodeKind.FunctionExpr) { return true; }
		const t = peelHidden(n).nodeType;
		return t !== null && t.kind === NodeKind.TypeFunction;
	}
	function isRawChild(n: Node): boolean {
		return isFunctionValued(n);
	}
	function isReactiveSelection(n: Node): boolean {
		const p = peelHidden(n);
		if (p.kind === NodeKind.ConditionalExpr) { return isReactiveExpr(p.ternaryCondition); }
		if (p.kind === NodeKind.BinaryExpr && (p.operator === "&&" || p.operator === "||" || p.operator === "??")) {
			return isReactiveExpr(p.left);
		}
		return false;
	}
	function showOf(when: Node, child: Node, fallback: Node | null, ln: int32, col: int32): Node {
		let attrs: Node[] = [{ kind: NodeKind.JSXAttribute, line: ln, column: col, jsxAttrName: "when", jsxAttrValue: when }];
		if (fallback !== null) {
			attrs.push({ kind: NodeKind.JSXAttribute, line: ln, column: col, jsxAttrName: "fallback", jsxAttrValue: fallback as Node });
		}
		return { kind: NodeKind.JSXElement, line: ln, column: col, jsxTag: "Show", jsxAttrs: attrs, jsxChildren: [child], jsxSelfClosing: false };
	}
	function forOf(each: Node, row: Node, ln: int32, col: int32): Node {
		return {
			kind: NodeKind.JSXElement, line: ln, column: col, jsxTag: "For",
			jsxAttrs: [{ kind: NodeKind.JSXAttribute, line: ln, column: col, jsxAttrName: "each", jsxAttrValue: each }],
			jsxChildren: [{ kind: NodeKind.JSXExpressionContainer, line: ln, column: col, jsxExpr: row }],
			jsxSelfClosing: false,
		};
	}
	function isJsx(n: Node): boolean {
		return n.kind === NodeKind.JSXElement || n.kind === NodeKind.JSXFragment;
	}
	const mapIndexRowMsg = "a .map row that takes an index is written <For each={xs}>{(x, i) => …}</For>, where the index is an Accessor<number> that follows the row";
	const reactiveNodeMsg = "a NeonNode child picked by a reactive condition would mount once and never switch — use <Show> or a JSX branch: {cond() ? <A/> : <B/>}";
	function lowerFlowTree(elNode: Node): Node {
		let kids: Node[] = [];
		for (const c of kidsOf(elNode)) {
			let lowered: Node | null = null;
			if (isJsx(c)) {
				lowered = lowerFlowTree(c);
			} else if (c.kind === NodeKind.JSXExpressionContainer) {
				const ex = peelHidden(c.jsxExpr);
				if (ex.kind === NodeKind.BinaryExpr && ex.operator === "&&") {
					const rhs = peelHidden(ex.right);
					if (isJsx(rhs)) { lowered = showOf(ex.left, lowerFlowTree(rhs), null, c.line, c.column); }
				} else if (ex.kind === NodeKind.BinaryExpr && ex.operator === "??") {
					const rhs = peelHidden(ex.right);
					if (isJsx(rhs)) {
						if (isReactiveExpr(ex.left)) { errNodes.push(ex.left); errMsgs.push(reactiveNodeMsg); }
						const present: Node = { kind: NodeKind.BinaryExpr, line: c.line, column: c.column, operator: "!==", left: ex.left, right: { kind: NodeKind.NullLiteral, line: c.line, column: c.column } };
						const held: Node = { kind: NodeKind.JSXExpressionContainer, line: c.line, column: c.column, jsxExpr: ex.left };
						lowered = showOf(present, held, lowerFlowTree(rhs), c.line, c.column);
					}
				} else if (ex.kind === NodeKind.ConditionalExpr) {
					const yes = peelHidden(ex.ternaryConsequent);
					const no = peelHidden(ex.ternaryAlternate);
					if (isJsx(yes) && isJsx(no)) {
						lowered = showOf(ex.ternaryCondition, lowerFlowTree(yes), lowerFlowTree(no), c.line, c.column);
					} else if (isJsx(yes) && no.kind === NodeKind.NullLiteral) {
						lowered = showOf(ex.ternaryCondition, lowerFlowTree(yes), null, c.line, c.column);
					} else if (yes.kind === NodeKind.NullLiteral && isJsx(no)) {
						const not: Node = { kind: NodeKind.UnaryExpr, line: c.line, column: c.column, unaryOp: "!", operand: ex.ternaryCondition };
						lowered = showOf(not, lowerFlowTree(no), null, c.line, c.column);
					}
				} else if (ex.kind === NodeKind.CallExpr && ex.arguments.length === 1) {
					const callee = peelHidden(ex.callee);
					const row = peelHidden(ex.arguments[0]);
					if (callee.kind === NodeKind.MemberExpr && callee.property === "map" && isFunctionValued(row)) {
						if (rowArity(row) > 1) { errNodes.push(row); errMsgs.push(mapIndexRowMsg); }
						lowered = forOf(peelHidden(callee.object), row, c.line, c.column);
					}
				}
			}
			if (lowered !== null) { const picked = lowered as Node; kids.push(picked); } else { kids.push(c); }
		}
		if (elNode.kind === NodeKind.JSXFragment) {
			return { kind: NodeKind.JSXFragment, line: elNode.line, column: elNode.column, jsxFragChildren: kids };
		}
		return { kind: NodeKind.JSXElement, line: elNode.line, column: elNode.column, jsxTag: elNode.jsxTag, jsxAttrs: elNode.jsxAttrs, jsxChildren: kids, jsxSelfClosing: elNode.jsxSelfClosing };
	}
	node = flattenFragments(lowerFlowTree(node));


	const keyedMsg = "<For keyed> takes true, false or a key function, written in place: the row's parameters differ in each case, so a computed value cannot choose between them";
	function forByKeyed(c: Node): Node {
		if (c.jsxTag !== "For") { return c; }
		let at = -1;
		for (let i = 0; i < c.jsxAttrs.length; i = i + 1) {
			const a = c.jsxAttrs[i];
			if (a.kind === NodeKind.JSXAttribute && a.jsxAttrName === "keyed") { at = i; }
		}
		if (at < 0) { return c; }
		const keyed = c.jsxAttrs[at];
		const value = peelHidden(keyed.jsxAttrValue);
		let tag = "For";
		let keep = false;
		if (value.kind === NodeKind.BooleanLiteral) {
			if (!value.boolValue) { tag = "ForUnkeyed"; }
		} else if (isFunctionValued(value)) {
			tag = "ForKeyedBy";
			keep = true;
		} else {
			error(keyedMsg, keyed);
		}
		let attrs: Node[] = [];
		for (let i = 0; i < c.jsxAttrs.length; i = i + 1) {
			if (i !== at || keep) { attrs.push(c.jsxAttrs[i]); }
		}
		return { kind: NodeKind.JSXElement, line: c.line, column: c.column, jsxTag: tag, jsxAttrs: attrs, jsxChildren: c.jsxChildren, jsxSelfClosing: c.jsxSelfClosing };
	}
	let showIdx = 0;
	function flowItem(made: Node, base: string): Node {
		if (base === "Show") { return made; }
		return { kind: NodeKind.CallExpr, line: made.line, column: made.column, callee: made.arguments[0], arguments: [made.arguments[1]] };
	}
	const matchWhenMsg = "<Match> takes no 'when': Solid's <Match when> is <Case when> here, so write <Match fallback={…}><Case when={…}>…</Case></Match>";
	const matchChildMsg = "<Match> holds only <Case> branches: write the branch as <Case when={…}>…</Case>";
	const strayCaseMsg = "<Case> is only a direct child of <Match>: write <Match><Case when={…}>…</Case></Match>, or <Show when={…}> for a single condition";
	function matchCall(c: Node): Node {
		const ln = c.line;
		const col = c.column;
		let bad = false;
		let attrs: Node[] = [];
		for (const a of c.jsxAttrs) {
			if (a.kind === NodeKind.JSXAttribute && a.jsxAttrName === "when") {
				error(matchWhenMsg, a);
				bad = true;
			} else {
				attrs.push(a);
			}
		}
		let arms: Node[] = [];
		for (const k of c.jsxChildren) {
			if (k.kind === NodeKind.JSXText && cleanJsxText(k.jsxText) === "") { continue; }
			if (k.kind === NodeKind.JSXElement && k.jsxTag === "Case") {
				arms.push(whenFlow(k, "Case"));
			} else {
				error(matchChildMsg, k);
				bad = true;
			}
		}
		if (bad) { return { kind: NodeKind.NullLiteral, line: ln, column: col }; }
		attrs.push({ kind: NodeKind.JSXAttribute, line: ln, column: col, jsxAttrName: "cases", jsxAttrValue: { kind: NodeKind.ArrayLiteral, line: ln, column: col, elements: arms } });
		return componentOf({ kind: NodeKind.JSXElement, line: ln, column: col, jsxTag: "Match", jsxAttrs: attrs, jsxChildren: [], jsxSelfClosing: true });
	}
	function whenFlow(c: Node, base: string): Node {
		const showKeyedMsg = "<" + base + " keyed> takes true or false, written in place: a function child receives an Accessor of the value, or the value itself when keyed, so a computed value cannot choose between them";
		const showArityMsg = "a <" + base + "> function child takes one parameter, the narrowed value";
		let whenAt = -1;
		let keyedAt = -1;
		for (let i = 0; i < c.jsxAttrs.length; i = i + 1) {
			const a = c.jsxAttrs[i];
			if (a.kind !== NodeKind.JSXAttribute) { continue; }
			if (a.jsxAttrName === "when") { whenAt = i; }
			if (a.jsxAttrName === "keyed") { keyedAt = i; }
		}
		if (whenAt < 0) {
			error("<" + base + "> requires the 'when' prop", c);
			return flowItem(componentOf(c), base);
		}
		let keyed = false;
		if (keyedAt >= 0) {
			const k = peelHidden(c.jsxAttrs[keyedAt].jsxAttrValue);
			if (k.kind === NodeKind.BooleanLiteral) { keyed = k.boolValue; } else { error(showKeyedMsg, c.jsxAttrs[keyedAt]); }
		}
		let significant: Node[] = [];
		for (const k of c.jsxChildren) {
			if (!(k.kind === NodeKind.JSXText && cleanJsxText(k.jsxText) === "")) { significant.push(k); }
		}
		let withValue = false;
		if (significant.length === 1 && significant[0].kind === NodeKind.JSXExpressionContainer) {
			const only = significant[0].jsxExpr;
			if (isFunctionValued(only) && !isNodeTyped(only)) {
				const arity = rowArity(only);
				if (arity > 1) { error(showArityMsg, only); }
				withValue = arity === 1;
			}
		}
		const ln = c.line;
		const col = c.column;
		const given = c.jsxAttrs[whenAt].jsxAttrValue;
		const source: Node = isAccessorTyped(given)
			? { kind: NodeKind.CallExpr, line: ln, column: col, callee: given, arguments: [] }
			: given;
		const name = "_s" + showIdx.toString();
		showIdx = showIdx + 1;
		const read: Node = { kind: NodeKind.CallExpr, line: ln, column: col, callee: ident(name, ln, col), arguments: [] };
		function truthy(of: Node): Node {
			return {
				kind: NodeKind.ConditionalExpr, line: ln, column: col, ternaryCondition: of,
				ternaryConsequent: { kind: NodeKind.BooleanLiteral, line: ln, column: col, boolValue: true },
				ternaryAlternate: { kind: NodeKind.BooleanLiteral, line: ln, column: col, boolValue: false },
			};
		}
		function attr(attrName: string, value: Node): Node {
			return { kind: NodeKind.JSXAttribute, line: ln, column: col, jsxAttrName: attrName, jsxAttrValue: value };
		}
		function unwrapped(of: Node): Node {
			return { kind: NodeKind.TypeAssertion, line: ln, column: col, asExpr: of, asType: "!" };
		}
		const plain = !keyed && !withValue;
		let tag = base;
		let attrs: Node[] = [];
		for (let i = 0; i < c.jsxAttrs.length; i = i + 1) {
			if (i === whenAt) { attrs.push(attr("when", truthy(plain ? source : read))); }
			else if (i !== keyedAt) { attrs.push(c.jsxAttrs[i]); }
		}
		if (keyed && !withValue) { tag = base + "Keyed"; }
		if (!keyed && withValue) { tag = base + "With"; attrs.push(attr("value", unwrapped(read))); }
		if (keyed && withValue) { tag = base + "KeyedWith"; attrs.push(attr("value", unwrapped(read))); }
		const inner = flowItem(componentOf({ kind: NodeKind.JSXElement, line: ln, column: col, jsxTag: tag, jsxAttrs: attrs, jsxChildren: c.jsxChildren, jsxSelfClosing: c.jsxSelfClosing }), base);
		if (plain) { return inner; }
		return {
			kind: NodeKind.CallExpr, line: ln, column: col, callee: ident(base === "Show" ? "showWhen" : "caseWhen", ln, col),
			arguments: [
				{ kind: NodeKind.ArrowFunction, line: ln, column: col, arrowParams: [], arrowParamTypes: [], arrowBody: source, arrowFlags: "", arrowReturnType: "" },
				{ kind: NodeKind.ArrowFunction, line: ln, column: col, arrowParams: [name], arrowParamTypes: [""], arrowBody: inner, arrowFlags: "", arrowReturnType: "" },
			],
		};
	}
	function contextProvider(given: Node): Node {
		let valued = false;
		for (const a of given.jsxAttrs) {
			if (a.kind === NodeKind.JSXAttribute && a.jsxAttrName === "value") { valued = true; }
		}
		if (!valued) {
			error("<" + given.jsxTag + "> needs a value prop: a context provider without one has nothing to provide", given);
		}
		return { kind: NodeKind.JSXElement, line: given.line, column: given.column, jsxTag: given.jsxTag + ".provider", jsxAttrs: given.jsxAttrs, jsxChildren: given.jsxChildren, jsxSelfClosing: given.jsxSelfClosing };
	}
	function typedBase(n: Node): string {
		const t = peelHidden(n).nodeType;
		if (t === null) { return ""; }
		const g = peelTypeRef(t as Node);
		if (g.kind !== NodeKind.TypeGeneric) { return ""; }
		const base = g.typExprBase;
		return base.kind === NodeKind.Identifier ? base.name : "";
	}
	function pathName(n: Node): string {
		const p = peelHidden(n);
		if (p.kind === NodeKind.Identifier) { return p.name; }
		if (p.kind === NodeKind.MemberExpr) {
			const head = pathName(p.object);
			return head === "" ? "" : head + "." + p.property;
		}
		return "";
	}
	function componentFn(c: Node): Node | null {
		if (c.jsxTag.indexOf(".") >= 0) { return null; }
		const sym = bindSym(c.jsxTag);
		if (sym === null) { return null; }
		const impl = getImpl(sym);
		if (impl === null) { return null; }
		const decl = impl as Node;
		componentHome = sym.resolvedSym.modulePath;
		if (decl.kind === NodeKind.FunctionDecl) { return decl; }
		if (decl.kind !== NodeKind.VariableDecl || childCount(decl) === 0) { return null; }
		const init = childAt(decl, 0);
		return init.kind === NodeKind.ArrowFunction || init.kind === NodeKind.FunctionExpr ? init : null;
	}
	function isFunctionNode(n: Node): boolean {
		return n.kind === NodeKind.ArrowFunction || n.kind === NodeKind.FunctionExpr || n.kind === NodeKind.FunctionDecl;
	}
	function isJsxNode(n: Node): boolean {
		const k = n.kind;
		return k === NodeKind.JSXElement || k === NodeKind.JSXFragment || k === NodeKind.JSXText
			|| k === NodeKind.JSXExpressionContainer || k === NodeKind.JSXAttribute || k === NodeKind.JSXSpreadAttribute;
	}
	function isComputeArg(call: Node, at: int32): boolean {
		const f = peelHidden(call.callee);
		if (f.kind !== NodeKind.Identifier) { return false; }
		const name = f.name;
		if (name === "createMemo" || name === "createAsyncMemo" || name === "createEffect" || name === "createRenderEffect") { return at === 0; }
		return name === "bindText" || name === "bindAttr" || name === "bindStyleAll" || name === "bindStyleProp";
	}
	function givesOwnedWrite(call: Node): boolean {
		if (call.arguments.length < 2) { return false; }
		const options = peelHidden(call.arguments[1]);
		if (options.kind === NodeKind.NullLiteral) { return false; }
		if (options.kind !== NodeKind.ObjectLiteral) { return true; }
		for (let i = 0; i < options.keys.length; i = i + 1) {
			if (options.keys[i] !== "ownedWrite") { continue; }
			const v = peelHidden(options.properties[i]);
			return !(v.kind === NodeKind.BooleanLiteral && !v.boolValue);
		}
		return false;
	}
	function plainSetter(f: Node): boolean {
		if (f.kind !== NodeKind.Identifier) { return false; }
		const impl = getImpl(f);
		if (impl === null || impl.kind !== NodeKind.DestructuringDecl) { return false; }
		const pattern = impl.destrPattern;
		const init = peelHidden(impl.destrInit);
		if (pattern.kind !== NodeKind.ArrayPattern || childCount(pattern) !== 2 || init.kind !== NodeKind.CallExpr) { return false; }
		const setter = childAt(pattern, 1);
		return setter.kind === NodeKind.Identifier && setter.name === f.name && pathName(init.callee) === "createSignal" && !givesOwnedWrite(init);
	}
	function refuseReactiveMisuse(c: Node): void {
		const fn = componentFn(c);
		if (fn === null) { return; }
		// .inbox/compiler/2026-10-15-macro-diagnostic-on-a-getimpl-node-names-the-expanding-file.md
		const home = componentHome === expansionFile() ? "" : " (<" + c.jsxTag + "> is declared in " + componentHome + ")";
		let awaited = false;
		function scan(n: Node, mode: int32): void {
			if (n.kind === NodeKind.ClassDecl || n.kind === NodeKind.MethodDecl || n.kind === NodeKind.MacroInvocation || isJsxNode(n)) { return; }
			const inner = isFunctionNode(n) ? 2 : mode;
			if (n.kind === NodeKind.CallExpr) {
				const f = peelHidden(n.callee);
				if (mode === 0) {
					let read: Node | null = null;
					if (typedBase(f) === "Accessor") { read = f; }
					if (f.kind === NodeKind.MemberExpr && f.property === "valueOf" && typedBase(f.object) === "Accessor") { read = f.object; }
					if (f.kind === NodeKind.Identifier && f.name === "valueOf" && n.arguments.length > 0 && typedBase(n.arguments[0]) === "Accessor") { read = n.arguments[0]; }
					if (read !== null) {
						const name = pathName(read as Node);
						error("[STRICT_READ_UNTRACKED] Reactive value " + (name === "" ? "" : "\"" + name + "\" ") + "read directly in <" + c.jsxTag + "> will not update. Move it into a tracking scope (JSX, a memo, or an effect's compute function), or read it once inside untrack(() => ...)." + home, read as Node);
					}
				}
				if (mode === 1 && !awaited && typedBase(f) === "Setter" && plainSetter(f)) {
					error("[REACTIVE_WRITE_IN_OWNED_SCOPE] Writing to reactive state with \"" + pathName(f) + "\" inside a computation of <" + c.jsxTag + "> is not allowed. Move the write into an event handler or an effect's second function, or set the `ownedWrite` option on the signal if this is intentional." + home, f);
				}
				scan(n.callee, mode);
				for (let i = 0; i < n.arguments.length; i = i + 1) {
					const arg = n.arguments[i];
					if (isComputeArg(n, i) && isFunctionNode(arg)) {
						const was = awaited;
						awaited = false;
						for (let j = 0; j < childCount(arg); j = j + 1) { scan(childAt(arg, j), 1); }
						awaited = was;
					} else {
						scan(arg, mode);
					}
				}
				return;
			}
			for (let i = 0; i < childCount(n); i = i + 1) { scan(childAt(n, i), inner); }
			if (n.kind === NodeKind.AwaitExpr) { awaited = true; }
		}
		for (let i = 0; i < childCount(fn as Node); i = i + 1) { scan(childAt(fn as Node, i), 0); }
	}
	function componentCall(given: Node): Node {
		if (given.jsxTag === "Match") { return matchCall(given); }
		if (given.jsxTag === "Case") {
			error(strayCaseMsg, given);
			return { kind: NodeKind.NullLiteral, line: given.line, column: given.column };
		}
		const c = isContextTag(given) ? contextProvider(given) : given;
		if (c.jsxTag === "Show") { return whenFlow(c, "Show"); }
		refuseReactiveMisuse(c);
		return componentOf(forByKeyed(c));
	}
	function componentOf(c: Node): Node {
		let keys: string[] = [];
		let values: Node[] = [];
		const declared = declaredProps(c);
		for (const a of c.jsxAttrs) {
			if (a.kind === NodeKind.JSXAttribute) {
				if (declared === null) { continue; }
				let slot: Node | null = null;
				for (let i = 0; i < declared.typExprFieldNames.length; i = i + 1) {
					if (declared.typExprFieldNames[i] === a.jsxAttrName) { slot = declared.typExprFieldTypes[i]; }
				}
				if (slot === null) {
					error("<" + c.jsxTag + "> has no prop '" + a.jsxAttrName + "'", a as Node);
					continue;
				}
				const reactive = accessorSlot(slot as Node);
				if (reactive < 0) {
					error("prop '" + a.jsxAttrName + "' of <" + c.jsxTag + "> mixes Accessor with another type: declare it Accessor<…> | null or a plain type", a as Node);
					continue;
				}
				keys.push(a.jsxAttrName);
				let given: Node = a.jsxAttrValue;
				// WORKAROUND.md N8.
				if (a.jsxAttrName === "style" && given.kind === NodeKind.ArrayLiteral) {
					given = { kind: NodeKind.CallExpr, line: a.line, column: a.column, callee: { kind: NodeKind.Identifier, line: a.line, column: a.column, name: "layerStyles" }, arguments: [given] };
				}
				if (a.jsxAttrName === "ref") { given = refSource(given); }
				if (reactive === 0 || isAccessorTyped(given)) {
					values.push(nodeSlot(slot as Node) ? lowerNodeSlot(given) : given);
				} else {
					values.push({ kind: NodeKind.CallExpr, line: a.line, column: a.column, callee: { kind: NodeKind.Identifier, line: a.line, column: a.column, name: "accessor" }, arguments: [{ kind: NodeKind.ArrowFunction, line: a.line, column: a.column, arrowParams: [], arrowParamTypes: [], arrowBody: given, arrowFlags: "", arrowReturnType: "" }] });
				}
			}
		}
		const tag = c.jsxTag;
		let significant: Node[] = [];
		for (const k of c.jsxChildren) {
			if (!(k.kind === NodeKind.JSXText && cleanJsxText(k.jsxText) === "")) { significant.push(k); }
		}
		if (significant.length === 1 && significant[0].kind === NodeKind.JSXExpressionContainer && isRawChild(significant[0].jsxExpr)) {
			const only = significant[0].jsxExpr;
			if (isNodeTyped(only) && isReactiveSelection(only)) { errNodes.push(only); errMsgs.push(reactiveNodeMsg); }
			keys.push("children");
			let child = only;
			if (declared !== null) {
				for (let i = 0; i < declared.typExprFieldNames.length; i = i + 1) {
					if (declared.typExprFieldNames[i] === "children" && nodeSlot(declared.typExprFieldTypes[i])) {
						child = lowerNodeSlot(only);
					}
				}
			}
			values.push(child);
		} else if (significant.length === 1 && significant[0].kind === NodeKind.JSXElement) {
			keys.push("children");
			values.push({ kind: NodeKind.MacroInvocation, line: significant[0].line, column: significant[0].column, macroName: "element", macroArgs: [significant[0]] });
		} else if (significant.length > 0) {
			keys.push("children");
			values.push({
				kind: NodeKind.MacroInvocation, line: c.line, column: c.column, macroName: "element",
				macroArgs: [{ kind: NodeKind.JSXFragment, line: c.line, column: c.column, jsxFragChildren: c.jsxChildren }],
			});
		}
		if (tag === "For" || tag === "ForKeyedBy") {
			let written = false;
			let rowAt = -1;
			for (let i = 0; i < keys.length; i = i + 1) {
				if (keys[i] === "usesIndex") { written = true; }
				if (keys[i] === "children") { rowAt = i; }
			}
			if (!written && rowAt >= 0) {
				keys.push("usesIndex");
				values.push({ kind: NodeKind.BooleanLiteral, line: c.line, column: c.column, boolValue: rowUsesIndex(values[rowAt]) });
			}
		}
		// A dotted tag (Palettes.tone) resolves through member access, not a flat
		// name: fold the parts so the checker sees Palettes.tone and types the call
		// through the field's declared component type.
		let tagRef: Node = { kind: NodeKind.Identifier, line: c.line, column: c.column, name: tag };
		if (tag.indexOf(".") >= 0) {
			const parts: string[] = tag.split(".");
			tagRef = { kind: NodeKind.Identifier, line: c.line, column: c.column, name: parts[0] };
			for (let i = 1; i < parts.length; i = i + 1) {
				tagRef = { kind: NodeKind.MemberExpr, line: c.line, column: c.column, object: tagRef, property: parts[i], isOptional: false };
			}
		}
		const fn = componentType(c);
		if (fn !== null) { tagRef = componentWithProps(tagRef, fn); }
		return {
			kind: NodeKind.CallExpr, line: c.line, column: c.column,
			callee: { kind: NodeKind.Identifier, line: c.line, column: c.column, name: "createComponent" },
			arguments: [
				tagRef,
				{ kind: NodeKind.ObjectLiteral, line: c.line, column: c.column, properties: values, keys: keys },
			],
		};
	}
	function isComponentTag(c: Node): boolean {
		const first = c.jsxTag.charAt(0);
		return first >= "A" && first <= "Z";
	}
	if (node.kind === NodeKind.JSXElement && isComponentTag(node)) {
		const call = componentCall(node);
		if (errNodes.length > 0) { error(errMsgs[0], errNodes[0]); }
		return call;
	}

	// ---- D4 template mode ----
	// A subtree of nothing but lowercase elements, text, attrs, events and style
	// has a STATIC skeleton: build it once, duplicate it per mount, and walk to
	// the dynamic spots along a path computed here at compile time. Component
	// tags and regions change structure at runtime, so a subtree containing one
	// keeps the D3 flat emission below, unchanged.
	function isPureSubtree(el: Node): boolean {
		for (const c of el.jsxChildren) {
			if (c.kind === NodeKind.JSXExpressionContainer && isNodeValued(c.jsxExpr)) { return false; }
			if (c.kind === NodeKind.JSXElement) {
				const t0 = c.jsxTag.charAt(0);
				if (t0 >= "A" && t0 <= "Z") { return false; }
				if (!isPureSubtree(c)) { return false; }
			}
		}
		return true;
	}

	// Does this element need a runtime handle in the instance (as opposed to
	// living entirely inside the template)? Only handles get walk steps.
	function needsHandle(el: Node): boolean {
		for (const a of el.jsxAttrs) {
			if (a.kind === NodeKind.JSXAttribute) {
				if (isEventName(a.jsxAttrName) || a.jsxAttrName === "ref") { return true; }
				if (a.jsxAttrValue.kind !== NodeKind.StringLiteral) { return true; }
			}
		}
		for (const c of el.jsxChildren) {
			if (c.kind === NodeKind.JSXExpressionContainer) { return true; }
			if (c.kind === NodeKind.JSXElement && needsHandle(c)) { return true; }
		}
		return false;
	}

	// A -d:server build writes markup in document order (src/render/ssr.ms), and a
	// template fills its holes after the skeleton is built, so the server keeps the
	// flat emission below.
	if (define("server") === "" && node.kind === NodeKind.JSXElement && isPureSubtree(node)) {
		let bStmts: Node[] = [];
		let wStmts: Node[] = [];
		let bIdx = 0;
		let pIdx = 1;
		let tsIdx = 0;

		// Skeleton: elements, static attrs, and a placeholder for every dynamic
		// slot. A dynamic attr keeps its SOURCE position with an empty value —
		// the per-instance effect upserts it, so markup order matches tree
		// emission (probe/tmplShape.ms "attr order" is the red-proof).
		function emitBuild(el: Node): string {
			const rName = "_r" + bIdx.toString();
			bIdx = bIdx + 1;
			bStmts.push({
				kind: NodeKind.VariableDecl, line: el.line, column: el.column,
				declName: rName, declType: "", declKind: DeclKind.Const,
				initializer: hostCall("h", "createElement", [strLit(el.jsxTag, el.line, el.column)], el.line, el.column),
			});
			for (const a of el.jsxAttrs) {
				if (a.kind === NodeKind.JSXAttribute) {
					if (isEventName(a.jsxAttrName)) { continue; }
					if (a.jsxAttrName === "ref") { continue; }
					if (a.jsxAttrName === "style" && a.jsxAttrValue.kind !== NodeKind.StringLiteral) { continue; }
					const v = a.jsxAttrValue.kind === NodeKind.StringLiteral ? a.jsxAttrValue : strLit("", a.line, a.column);
					bStmts.push({
						kind: NodeKind.ExprStmt, line: a.line, column: a.column,
						expr: hostCall("h", "setAttr", [ident(rName, a.line, a.column), strLit(a.jsxAttrName, a.line, a.column), v], a.line, a.column),
					});
				}
			}
			for (const c of el.jsxChildren) {
				if (c.kind === NodeKind.JSXText) {
					const cleaned = cleanJsxText(c.jsxText);
					if (cleaned !== "") {
						bStmts.push({
							kind: NodeKind.ExprStmt, line: c.line, column: c.column,
							expr: hostCall("h", "append", [ident(rName, c.line, c.column), hostCall("h", "createText", [strLit(cleaned, c.line, c.column)], c.line, c.column)], c.line, c.column),
						});
					}
				} else if (c.kind === NodeKind.JSXExpressionContainer) {
					bStmts.push({
						kind: NodeKind.ExprStmt, line: c.line, column: c.column,
						expr: hostCall("h", "append", [ident(rName, c.line, c.column), hostCall("h", "createText", [strLit("", c.line, c.column)], c.line, c.column)], c.line, c.column),
					});
				} else if (c.kind === NodeKind.JSXElement) {
					const kid = emitBuild(c);
					bStmts.push({
						kind: NodeKind.ExprStmt, line: c.line, column: c.column,
						expr: hostCall("h", "append", [ident(rName, c.line, c.column), ident(kid, c.line, c.column)], c.line, c.column),
					});
				}
			}
			return rName;
		}

		// Per-instance wiring: dynamic attrs (one effect each), events, style,
		// then the walk into children that carry dynamic spots.
		function emitWire(el: Node, elVar: string): void {
			let wRef: Node | null = null;
			for (const a of el.jsxAttrs) {
				if (a.kind === NodeKind.JSXAttribute) {
					if (a.jsxAttrName === "ref") {
						wRef = a.jsxAttrValue;
						continue;
					}
					if (a.jsxAttrName === "style" && a.jsxAttrValue.kind !== NodeKind.StringLiteral) {
						const sv = a.jsxAttrValue;
						if (sv.kind === NodeKind.ObjectLiteral) {
							pushStyleObject(wStmts, sv, elVar, "_ts" + tsIdx.toString(), a.line, a.column);
							tsIdx = tsIdx + 1;
						} else if (sv.kind === NodeKind.ArrayLiteral) {
							pushStyleLayers(wStmts, sv, elVar, "_ts" + tsIdx.toString(), a.line, a.column);
							tsIdx = tsIdx + 1;
						} else if (!isReactiveExpr(sv) && presentKind(sv) !== "") {
							pushWhenPresent(wStmts, ident(presentKind(sv) === "accessor" ? "bindStyleAll" : "applyStaticStyle", a.line, a.column), [ident("host", a.line, a.column), ident(elVar, a.line, a.column)], sv, [], a.line, a.column);
						} else if (isReactiveExpr(sv) || isAccessorTyped(sv)) {
							wStmts.push({
								kind: NodeKind.ExprStmt, line: a.line, column: a.column,
								expr: {
									kind: NodeKind.CallExpr, line: a.line, column: a.column,
									callee: ident("bindStyleAll", a.line, a.column),
									arguments: [
										ident("host", a.line, a.column),
										ident(elVar, a.line, a.column),
										{
											kind: NodeKind.ArrowFunction, line: a.line, column: a.column,
											arrowParams: [], arrowParamTypes: [], arrowFlags: "", arrowReturnType: "",
											arrowBody: sv,
										},
									],
								},
							});
						} else {
							const sName = "_ts" + tsIdx.toString();
							tsIdx = tsIdx + 1;
							wStmts.push({
								kind: NodeKind.VariableDecl, line: a.line, column: a.column,
								declName: sName, declType: "", declKind: DeclKind.Const,
								initializer: sv,
							});
							wStmts.push({
								kind: NodeKind.ExprStmt, line: a.line, column: a.column,
								expr: {
									kind: NodeKind.CallExpr, line: a.line, column: a.column,
									callee: ident("applyStaticStyle", a.line, a.column),
									arguments: [ident("host", a.line, a.column), ident(elVar, a.line, a.column), ident(sName, a.line, a.column)],
								},
							});
						}
					} else if (isEventName(a.jsxAttrName) && presentKind(a.jsxAttrValue) !== "") {
						if (a.jsxAttrName === "onChangeText") {
							errNodes.push(a.jsxAttrValue);
							errMsgs.push(optChangeTextMsg);
						} else {
							pushWhenPresent(wStmts, { kind: NodeKind.MemberExpr, line: a.line, column: a.column, object: ident("host", a.line, a.column), property: "addEvent", isOptional: false }, [ident(elVar, a.line, a.column), strLit(a.jsxAttrName, a.line, a.column)], a.jsxAttrValue, [], a.line, a.column);
						}
					} else if (isEventName(a.jsxAttrName)) {
						// onChangeText text-unwrap — mirrors element.ms, see the comment there.
						let hVal: Node = a.jsxAttrValue;
						if (a.jsxAttrName === "onChangeText") {
							hVal = { kind: NodeKind.ArrowFunction, line: a.line, column: a.column, arrowParams: ["__msCte"], arrowParamTypes: [""], arrowFlags: "", arrowReturnType: "", arrowBody: { kind: NodeKind.CallExpr, line: a.line, column: a.column, callee: a.jsxAttrValue, arguments: [{ kind: NodeKind.MemberExpr, line: a.line, column: a.column, object: { kind: NodeKind.Identifier, line: a.line, column: a.column, name: "__msCte" }, property: "value", isOptional: false }] } };
						}
						wStmts.push({
							kind: NodeKind.ExprStmt, line: a.line, column: a.column,
							expr: hostCall("host", "addEvent", [ident(elVar, a.line, a.column), strLit(a.jsxAttrName, a.line, a.column), hVal], a.line, a.column),
						});
					} else if (presentKind(a.jsxAttrValue) === "accessor") {
						pushAttrWhenPresent(wStmts, elVar, a.jsxAttrName, a.jsxAttrValue, [{
							kind: NodeKind.ExprStmt, line: a.line, column: a.column,
							expr: hostCall("host", "removeAttr", [ident(elVar, a.line, a.column), strLit(a.jsxAttrName, a.line, a.column)], a.line, a.column),
						}], a.line, a.column);
					} else if (a.jsxAttrValue.kind !== NodeKind.StringLiteral) {
						wStmts.push({
							kind: NodeKind.ExprStmt, line: a.line, column: a.column,
							expr: !isReactiveExpr(a.jsxAttrValue) && !isAccessorTyped(a.jsxAttrValue) ? {
								kind: NodeKind.CallExpr, line: a.line, column: a.column,
								callee: ident("writeAttr", a.line, a.column),
								arguments: [ident("host", a.line, a.column), ident(elVar, a.line, a.column), strLit(a.jsxAttrName, a.line, a.column), a.jsxAttrValue],
							} : {
								kind: NodeKind.CallExpr, line: a.line, column: a.column,
								callee: ident("bindAttr", a.line, a.column),
								arguments: [
									ident("host", a.line, a.column),
									ident(elVar, a.line, a.column),
									strLit(a.jsxAttrName, a.line, a.column),
									{
										kind: NodeKind.ArrowFunction, line: a.line, column: a.column,
										arrowParams: [], arrowParamTypes: [], arrowFlags: "", arrowReturnType: "",
										arrowBody: a.jsxAttrValue,
									},
								],
							},
						});
					}
				}
			}

			let lastVar = "";
			let lastIdx = 0 - 1;
			let slot = 0;
			for (const c of el.jsxChildren) {
				let occupies = true;
				let wants = false;
				if (c.kind === NodeKind.JSXText) {
					occupies = cleanJsxText(c.jsxText) !== "";
				} else if (c.kind === NodeKind.JSXExpressionContainer) {
					wants = true;
				} else if (c.kind === NodeKind.JSXElement) {
					wants = needsHandle(c);
				} else {
					occupies = false;
				}
				if (!occupies) { continue; }
				if (wants) {
					let curVar = lastVar;
					let k = lastIdx;
					if (lastVar === "") {
						curVar = "_p" + pIdx.toString();
						pIdx = pIdx + 1;
						wStmts.push({
							kind: NodeKind.VariableDecl, line: c.line, column: c.column,
							declName: curVar, declType: "", declKind: DeclKind.Const,
							initializer: {
								kind: NodeKind.CallExpr, line: c.line, column: c.column,
								callee: ident("childOf", c.line, c.column),
								arguments: [ident("host", c.line, c.column), ident(elVar, c.line, c.column)],
							},
						});
						k = 0;
					}
					while (k < slot) {
						const nextVar = "_p" + pIdx.toString();
						pIdx = pIdx + 1;
						wStmts.push({
							kind: NodeKind.VariableDecl, line: c.line, column: c.column,
							declName: nextVar, declType: "", declKind: DeclKind.Const,
							initializer: {
								kind: NodeKind.CallExpr, line: c.line, column: c.column,
								callee: ident("siblingOf", c.line, c.column),
								arguments: [ident("host", c.line, c.column), ident(curVar, c.line, c.column)],
							},
						});
						curVar = nextVar;
						k = k + 1;
					}
					lastVar = curVar;
					lastIdx = slot;
					if (c.kind === NodeKind.JSXExpressionContainer) {
						wStmts.push({
							kind: NodeKind.ExprStmt, line: c.line, column: c.column,
							expr: !isReactiveExpr(c.jsxExpr) && !isAccessorTyped(c.jsxExpr) ? hostCall("host", "setText", [ident(curVar, c.line, c.column), asText(c.jsxExpr)], c.line, c.column) : {
								kind: NodeKind.CallExpr, line: c.line, column: c.column,
								callee: ident("bindText", c.line, c.column),
								arguments: [
									ident("host", c.line, c.column),
									ident(curVar, c.line, c.column),
									{
										kind: NodeKind.ArrowFunction, line: c.line, column: c.column,
										arrowParams: [], arrowParamTypes: [], arrowFlags: "", arrowReturnType: "",
										arrowBody: asText(c.jsxExpr),
									},
								],
							},
						});
					} else {
						emitWire(c, curVar);
					}
				}
				slot = slot + 1;
			}

			if (wRef !== null) { pushRef(wStmts, el.jsxTag, elVar, wRef as Node, el.line, el.column); }
		}

		const tplRoot = emitBuild(node);
		emitWire(node, "_p0");
		if (errNodes.length > 0) { error(errMsgs[0], errNodes[0]); }
		bStmts.push({
			kind: NodeKind.ReturnStmt, line: L, column: C,
			argument: { kind: NodeKind.Identifier, line: L, column: C, name: tplRoot },
		});

		const tplName = "_tpl" + L.toString() + "_" + C.toString();
		return {
			kind: NodeKind.SpliceMany, line: L, column: C,
			spliceNodes: [
				{
					kind: NodeKind.VariableDecl, line: L, column: C,
					flags: (0 as BitSet<NodeFlag>).incl(NodeFlag.StaticStorage),
					declName: tplName, declType: "", declKind: DeclKind.Const,
					nameLocation: { line: L, column: C },
					initializer: {
						kind: NodeKind.CallExpr, line: L, column: C,
						callee: { kind: NodeKind.Identifier, line: L, column: C, name: "createTemplate" },
						arguments: [{
							kind: NodeKind.ArrowFunction, line: L, column: C,
							arrowParams: ["h"], arrowParamTypes: ["Host"], arrowFlags: "", arrowReturnType: "HostNode",
							arrowBody: { kind: NodeKind.BlockStmt, line: L, column: C, statements: bStmts },
						}],
					},
				},
				{
					kind: NodeKind.CallExpr, line: L, column: C,
					callee: { kind: NodeKind.Identifier, line: L, column: C, name: "mountTemplate" },
					arguments: [
						{ kind: NodeKind.Identifier, line: L, column: C, name: tplName },
						{
							kind: NodeKind.ArrowFunction, line: L, column: C,
							arrowParams: ["host", "_p0"], arrowParamTypes: ["Host", "HostNode"], arrowFlags: "", arrowReturnType: "void",
							arrowBody: { kind: NodeKind.BlockStmt, line: L, column: C, statements: wStmts },
						},
					],
				},
			],
		};
	}

	let stmts: Node[] = [];
	let rIdx = 0;
	let tIdx = 0;
	let kIdx = 0;
	let sIdx = 0;

	function pushInsert(parentVar: string, child: Node, atRoot: boolean, ln: int32, col: int32): void {
		stmts.push({
			kind: NodeKind.ExprStmt, line: ln, column: col,
			expr: atRoot ? {
				kind: NodeKind.CallExpr, line: ln, column: col,
				callee: ident("place", ln, col),
				arguments: [ident("host", ln, col), ident(parentVar, ln, col), child, ident("before", ln, col)],
			} : hostCall("host", "append", [ident(parentVar, ln, col), child], ln, col),
		});
	}

	function emitKids(list: Node[], parentVar: string, atRoot: boolean): void {
		for (const c of list) {
			const beforeArg: Node = atRoot ? ident("before", c.line, c.column) : { kind: NodeKind.NullLiteral, line: c.line, column: c.column };
			if (c.kind === NodeKind.JSXText) {
				const cleaned = cleanJsxText(c.jsxText);
				if (cleaned !== "") {
					pushInsert(parentVar, hostCall("host", "createText", [strLit(cleaned, c.line, c.column)], c.line, c.column), atRoot, c.line, c.column);
				}
			} else if (c.kind === NodeKind.JSXExpressionContainer) {
				const nodeValued = isNodeValued(c.jsxExpr);
				if (nodeValued && isReactiveSelection(c.jsxExpr)) { errNodes.push(c.jsxExpr); errMsgs.push(reactiveNodeMsg); }
				const liveSpot = !nodeValued && (isReactiveExpr(c.jsxExpr) || isAccessorTyped(c.jsxExpr));
				if (isNullableNodeTyped(c.jsxExpr)) {
					pushWhenPresent(stmts, ident("mountChild", c.line, c.column), [ident("host", c.line, c.column), ident(parentVar, c.line, c.column), beforeArg], c.jsxExpr, [], c.line, c.column);
					continue;
				}
				if (!liveSpot) {
					stmts.push({
						kind: NodeKind.ExprStmt, line: c.line, column: c.column,
						expr: {
							kind: NodeKind.CallExpr, line: c.line, column: c.column,
							callee: ident("mountChild", c.line, c.column),
							arguments: [ident("host", c.line, c.column), ident(parentVar, c.line, c.column), beforeArg, asText(c.jsxExpr)],
						},
					});
					continue;
				}
				const tName = "_t" + tIdx.toString();
				tIdx = tIdx + 1;
				stmts.push({
					kind: NodeKind.VariableDecl, line: c.line, column: c.column,
					declName: tName, declType: "", declKind: DeclKind.Const,
					initializer: hostCall("host", "createText", [strLit("", c.line, c.column)], c.line, c.column),
				});
				stmts.push({
					kind: NodeKind.ExprStmt, line: c.line, column: c.column,
					expr: {
						kind: NodeKind.CallExpr, line: c.line, column: c.column,
						callee: ident("bindText", c.line, c.column),
						arguments: [
							ident("host", c.line, c.column),
							ident(tName, c.line, c.column),
							{
								kind: NodeKind.ArrowFunction, line: c.line, column: c.column,
								arrowParams: [], arrowParamTypes: [], arrowFlags: "", arrowReturnType: "",
								arrowBody: asText(c.jsxExpr),
							},
						],
					},
				});
				pushInsert(parentVar, ident(tName, c.line, c.column), atRoot, c.line, c.column);
			} else if (c.kind === NodeKind.JSXElement && isComponentTag(c)) {
				const kName = "_k" + kIdx.toString();
				kIdx = kIdx + 1;
				stmts.push({
					kind: NodeKind.VariableDecl, line: c.line, column: c.column,
					declName: kName, declType: "", declKind: DeclKind.Const,
					initializer: componentCall(c),
				});
				stmts.push({
					kind: NodeKind.ExprStmt, line: c.line, column: c.column,
					expr: {
						kind: NodeKind.CallExpr, line: c.line, column: c.column,
						callee: ident(kName, c.line, c.column),
						arguments: [ident("host", c.line, c.column), ident(parentVar, c.line, c.column), beforeArg],
					},
				});
			} else if (c.kind === NodeKind.JSXElement) {
				const el = c;
				const rName = "_r" + rIdx.toString();
				let refFor: Node | null = null;
				rIdx = rIdx + 1;
				stmts.push({
					kind: NodeKind.VariableDecl, line: el.line, column: el.column,
					declName: rName, declType: "", declKind: DeclKind.Const,
					initializer: hostCall("host", "createElement", [strLit(el.jsxTag, el.line, el.column)], el.line, el.column),
				});

				for (const a of el.jsxAttrs) {
					if (a.kind === NodeKind.JSXAttribute) {
						if (a.jsxAttrName === "ref") {
							refFor = a.jsxAttrValue;
							continue;
						}
						if (a.jsxAttrName === "style" && a.jsxAttrValue.kind !== NodeKind.StringLiteral) {
							const sv = a.jsxAttrValue;
							if (sv.kind === NodeKind.ObjectLiteral) {
								pushStyleObject(stmts, sv, rName, "_s" + sIdx.toString(), a.line, a.column);
								sIdx = sIdx + 1;
								continue;
							}
							if (sv.kind === NodeKind.ArrayLiteral) {
								pushStyleLayers(stmts, sv, rName, "_s" + sIdx.toString(), a.line, a.column);
								sIdx = sIdx + 1;
								continue;
							}
							if (!isReactiveExpr(sv) && presentKind(sv) !== "") {
								pushWhenPresent(stmts, { kind: NodeKind.Identifier, line: a.line, column: a.column, name: presentKind(sv) === "accessor" ? "bindStyleAll" : "applyStaticStyle" }, [{ kind: NodeKind.Identifier, line: a.line, column: a.column, name: "host" }, { kind: NodeKind.Identifier, line: a.line, column: a.column, name: rName }], sv, [], a.line, a.column);
								continue;
							}
							if (isReactiveExpr(sv) || isAccessorTyped(sv)) {
								stmts.push({
									kind: NodeKind.ExprStmt, line: a.line, column: a.column,
									expr: {
										kind: NodeKind.CallExpr, line: a.line, column: a.column,
										callee: { kind: NodeKind.Identifier, line: a.line, column: a.column, name: "bindStyleAll" },
										arguments: [
											{ kind: NodeKind.Identifier, line: a.line, column: a.column, name: "host" },
											{ kind: NodeKind.Identifier, line: a.line, column: a.column, name: rName },
											{
												kind: NodeKind.ArrowFunction, line: a.line, column: a.column,
												arrowParams: [], arrowParamTypes: [], arrowFlags: "", arrowReturnType: "",
												arrowBody: sv,
											},
										],
									},
								});
								continue;
							}
							// Bind the style expr to a temp before the call: BUGS.md §2 call-result
							// arg at an address-taken position (same reason as the _e child temps).
							const sName = "_s" + sIdx.toString();
							sIdx = sIdx + 1;
							stmts.push({
								kind: NodeKind.VariableDecl, line: a.line, column: a.column,
								declName: sName, declType: "", declKind: DeclKind.Const,
								initializer: sv,
							});
							stmts.push({
								kind: NodeKind.ExprStmt, line: a.line, column: a.column,
								expr: {
									kind: NodeKind.CallExpr, line: a.line, column: a.column,
									callee: { kind: NodeKind.Identifier, line: a.line, column: a.column, name: "applyStaticStyle" },
									arguments: [
										{ kind: NodeKind.Identifier, line: a.line, column: a.column, name: "host" },
										{ kind: NodeKind.Identifier, line: a.line, column: a.column, name: rName },
										{ kind: NodeKind.Identifier, line: a.line, column: a.column, name: sName },
									],
								},
							});
							continue;
						}
						const nameLit: Node = { kind: NodeKind.StringLiteral, line: a.line, column: a.column, value: a.jsxAttrName };
						if (isEventName(a.jsxAttrName) && presentKind(a.jsxAttrValue) !== "") {
							if (a.jsxAttrName === "onChangeText") {
								errNodes.push(a.jsxAttrValue);
								errMsgs.push(optChangeTextMsg);
							} else {
								pushWhenPresent(stmts, { kind: NodeKind.MemberExpr, line: a.line, column: a.column, object: { kind: NodeKind.Identifier, line: a.line, column: a.column, name: "host" }, property: "addEvent", isOptional: false }, [{ kind: NodeKind.Identifier, line: a.line, column: a.column, name: rName }, nameLit], a.jsxAttrValue, [], a.line, a.column);
							}
						} else if (isEventName(a.jsxAttrName)) {
							// onChangeText text-unwrap — mirrors element.ms, see the comment there.
							let hVal: Node = a.jsxAttrValue;
							if (a.jsxAttrName === "onChangeText") {
								hVal = { kind: NodeKind.ArrowFunction, line: a.line, column: a.column, arrowParams: ["__msCte"], arrowParamTypes: [""], arrowFlags: "", arrowReturnType: "", arrowBody: { kind: NodeKind.CallExpr, line: a.line, column: a.column, callee: a.jsxAttrValue, arguments: [{ kind: NodeKind.MemberExpr, line: a.line, column: a.column, object: { kind: NodeKind.Identifier, line: a.line, column: a.column, name: "__msCte" }, property: "value", isOptional: false }] } };
							}
							stmts.push({
								kind: NodeKind.ExprStmt, line: a.line, column: a.column,
								expr: {
									kind: NodeKind.CallExpr, line: a.line, column: a.column,
									callee: { kind: NodeKind.MemberExpr, line: a.line, column: a.column, object: { kind: NodeKind.Identifier, line: a.line, column: a.column, name: "host" }, property: "addEvent", isOptional: false },
									arguments: [
										{ kind: NodeKind.Identifier, line: a.line, column: a.column, name: rName },
										nameLit,
										hVal,
									],
								},
							});
						} else if (a.jsxAttrValue.kind === NodeKind.StringLiteral) {
							stmts.push({
								kind: NodeKind.ExprStmt, line: a.line, column: a.column,
								expr: {
									kind: NodeKind.CallExpr, line: a.line, column: a.column,
									callee: { kind: NodeKind.MemberExpr, line: a.line, column: a.column, object: { kind: NodeKind.Identifier, line: a.line, column: a.column, name: "host" }, property: "setAttr", isOptional: false },
									arguments: [
										{ kind: NodeKind.Identifier, line: a.line, column: a.column, name: rName },
										nameLit,
										a.jsxAttrValue,
									],
								},
							});
						} else if (presentKind(a.jsxAttrValue) === "accessor") {
							pushAttrWhenPresent(stmts, rName, a.jsxAttrName, a.jsxAttrValue, [], a.line, a.column);
						} else {
							stmts.push({
								kind: NodeKind.ExprStmt, line: a.line, column: a.column,
								expr: !isReactiveExpr(a.jsxAttrValue) && !isAccessorTyped(a.jsxAttrValue) ? {
									kind: NodeKind.CallExpr, line: a.line, column: a.column,
									callee: { kind: NodeKind.Identifier, line: a.line, column: a.column, name: "writeAttr" },
									arguments: [
										{ kind: NodeKind.Identifier, line: a.line, column: a.column, name: "host" },
										{ kind: NodeKind.Identifier, line: a.line, column: a.column, name: rName },
										nameLit,
										a.jsxAttrValue,
									],
								} : {
									kind: NodeKind.CallExpr, line: a.line, column: a.column,
									callee: { kind: NodeKind.Identifier, line: a.line, column: a.column, name: "bindAttr" },
									arguments: [
										{ kind: NodeKind.Identifier, line: a.line, column: a.column, name: "host" },
										{ kind: NodeKind.Identifier, line: a.line, column: a.column, name: rName },
										nameLit,
										{
											kind: NodeKind.ArrowFunction, line: a.line, column: a.column,
											arrowParams: [], arrowParamTypes: [], arrowFlags: "", arrowReturnType: "",
											arrowBody: a.jsxAttrValue,
										},
									],
								},
							});
						}
					}
				}

				emitKids(el.jsxChildren, rName, false);

				if (!atRoot) { pushInsert(parentVar, ident(rName, el.line, el.column), atRoot, el.line, el.column); }
				if (refFor !== null) { pushRef(stmts, el.jsxTag, rName, refFor as Node, el.line, el.column); }
				if (atRoot) { pushInsert(parentVar, ident(rName, el.line, el.column), atRoot, el.line, el.column); }
			}
		}
	}

	emitKids(node.kind === NodeKind.JSXFragment ? node.jsxFragChildren : [node], "parent", true);
	if (errNodes.length > 0) { error(errMsgs[0], errNodes[0]); }

	return {
		kind: NodeKind.ArrowFunction, line: L, column: C,
		arrowParams: ["host", "parent", "before"], arrowParamTypes: ["Host", "HostNode", "HostNode | null"], arrowFlags: "", arrowReturnType: "void",
		arrowBody: { kind: NodeKind.BlockStmt, line: L, column: C, statements: stmts },
	};
}
