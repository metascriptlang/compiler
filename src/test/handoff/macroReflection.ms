import { compileToCWithStd } from "../helpers";

test "macro reflection: object field names and types" {
	const result = compileToCWithStd(`
import { Node, NodeKind } from "std/meta";

interface User { name: string; age: int32; }

export macro fieldsOf(t: Node): Node {
	let tt = t.nodeType;
	if (tt.kind === NodeKind.TypeGeneric) {
		tt = tt.typExprArgs[0];
	}
	let names: string = "";
	if (tt.kind === NodeKind.TypeObject) {
		let i = 0;
		while (i < tt.typExprFieldNames.length) {
			if (i > 0) { names = names + ","; }
			names = names + tt.typExprFieldNames[i];
			const ft = tt.typExprFieldTypes[i];
			if (ft.kind === NodeKind.Identifier) {
				names = names + ":" + ft.name;
			}
			i = i + 1;
		}
	}
	if (names !== "name:string,age:int32") { error("reflected shape mismatch: " + names, t); }
	return { kind: NodeKind.StringLiteral, line: t.line, column: t.column, value: names };
}

function main(): void {
	const u: User = { name: "a", age: 3 };
	const s: string = fieldsOf(u);
	console.log(s);
}
`);
	assert result.ok, result.ok ? "" : result.error;
}

test "macro reflection: value types preserve unknown and narrowed union views" {
	const result = compileToCWithStd(`
import { Node, NodeKind, stringValue } from "std/meta";

type Shape = { kind: "circle", r: number } | { kind: "square", s: number };

export macro unionInfo(t: Node, expected: Node): Node {
	let tt = t.nodeType;
	if (tt.kind === NodeKind.TypeGeneric) {
		tt = tt.typExprArgs[0];
	}
	let desc: string = "";
	if (tt.kind === NodeKind.TypeUnion) {
		let circle = false;
		let square = false;
		for (const raw of tt.typExprMembers) {
			let member = raw;
			if (member.kind === NodeKind.TypeGeneric) member = member.typExprArgs[0];
			if (member.kind !== NodeKind.TypeObject) { error("expected object union arm", t); }
			if (member.typExprFieldNames.length !== 2) { error("union arm lost fields", t); }
			let tag = "";
			let payload = "";
			for (let i: int32 = 0; i < member.typExprFieldNames.length; i++) {
				const name = member.typExprFieldNames[i];
				const field = member.typExprFieldTypes[i];
				if (name === "kind") {
					if (field.kind !== NodeKind.StringLiteral) { error("discriminant lost literal type", t); }
					tag = stringValue(field);
				} else {
					if (field.kind !== NodeKind.Identifier || field.name !== "number") { error("union payload lost numeric type", t); }
					payload = name;
				}
			}
			if (tag === "circle" && payload === "r") circle = true;
			else if (tag === "square" && payload === "s") square = true;
			else { error("union arm fields do not match its literal discriminant", t); }
		}
		if (!circle || !square) { error("union lost a distinct arm", t); }
		desc = "union:" + tt.typExprMembers.length;
	} else if (tt.kind === NodeKind.TypeObject) {
		desc = "object:";
		for (let i: int32 = 0; i < tt.typExprFieldNames.length; i++) {
			if (i > 0) desc = desc + ",";
			desc = desc + tt.typExprFieldNames[i];
			const field = tt.typExprFieldTypes[i];
			if (field.kind === NodeKind.StringLiteral) desc = desc + "=" + stringValue(field);
		}
	}
	if (desc !== stringValue(expected)) { error("reflected value shape mismatch: " + desc, t); }
	return { kind: NodeKind.StringLiteral, line: t.line, column: t.column, value: desc };
}

function inspectUnknown(sh: Shape): void {
	const whole = unionInfo(sh, "union:2");
	if (sh.kind === "circle") {
		const circle = unionInfo(sh, "object:kind=circle,r");
	} else {
		const square = unionInfo(sh, "object:kind=square,s");
	}
}

function main(): void {
	const sh: Shape = { kind: "circle", r: 5.0 };
	const narrowed = unionInfo(sh, "object:kind=circle,r");
	inspectUnknown(sh);
}
`);
	assert result.ok, result.ok ? "" : result.error;
}

test "macro reflection: reflected nodes cross typed helper parameters" {
	const result = compileToCWithStd(`
import { Node, NodeKind } from "std/meta";

interface User { name: string; age: int32; }

export function describeType(n: Node): NodeKind {
	return n.kind;
}

export macro viaHelper(t: Node): Node {
	let tt = t.nodeType;
	if (tt.kind === NodeKind.TypeGeneric) {
		tt = tt.typExprArgs[0];
	}
	const kind: NodeKind = describeType(tt);
	if (kind !== NodeKind.TypeObject) { error("helper lost reflected node kind", t); }
	return { kind: NodeKind.StringLiteral, line: t.line, column: t.column, value: "object" };
}

function main(): void {
	const u: User = { name: "a", age: 3 };
	const s: string = viaHelper(u);
	console.log(s);
}
`);
	assert result.ok, result.ok ? "" : result.error;
}

const witnessValidationSource = `
import { Node, NodeKind } from "std/meta";

interface Style { width: number; color: string; }

export macro checkKeys(w: Node, obj: Node): Node {
	let tt = w.nodeType;
	if (tt.kind === NodeKind.TypeGeneric) {
		tt = tt.typExprArgs[0];
	}
	if (obj.kind === NodeKind.ObjectLiteral && tt.kind === NodeKind.TypeObject) {
		let i = 0;
		while (i < obj.keys.length) {
			let found = false;
			let j = 0;
			while (j < tt.typExprFieldNames.length) {
				if (obj.keys[i] === tt.typExprFieldNames[j]) { found = true; }
				j = j + 1;
			}
			if (!found) {
				let avail = "";
				let k = 0;
				while (k < tt.typExprFieldNames.length) {
					if (k > 0) { avail = avail + ", "; }
					avail = avail + tt.typExprFieldNames[k];
					k = k + 1;
				}
				error("checkKeys: unknown key '" + obj.keys[i] + "' — available: " + avail, obj);
			}
			i = i + 1;
		}
	}
	return obj;
}

function main(): void {
	const w: Style = { width: 1, color: "x" };
	const s: Style = checkKeys(w, { width: 5, colr: "red" });
}
`;

test "macro reflection: macro rejects unknown literal keys with its own message" {
	const c = compileToCWithStd(witnessValidationSource);
	assert !c.ok;
	assert c.error.indexOf("unknown key 'colr'", 0) >= 0;
	assert c.error.indexOf("available: width, color", 0) >= 0;
}

const namedShapeMacro = `
import { Node, NodeKind } from "std/meta";

interface Style { width: number; color: string; }

export macro createStyles(sheet: Node): Node {
	const st = getTypeImpl(Style);
	if (sheet.kind === NodeKind.ObjectLiteral && st.kind === NodeKind.TypeObject) {
		let e = 0;
		while (e < sheet.properties.length) {
			const entry = sheet.properties[e];
			if (entry.kind === NodeKind.ObjectLiteral) {
				let i = 0;
				while (i < entry.keys.length) {
					let found = false;
					let j = 0;
					while (j < st.typExprFieldNames.length) {
						if (entry.keys[i] === st.typExprFieldNames[j]) { found = true; }
						j = j + 1;
					}
					if (!found) {
						let avail = "";
						let k = 0;
						while (k < st.typExprFieldNames.length) {
							if (k > 0) { avail = avail + ", "; }
							avail = avail + st.typExprFieldNames[k];
							k = k + 1;
						}
						error("createStyles: unknown style field '" + entry.keys[i] + "' in '" + sheet.keys[e] + "' — available: " + avail, entry);
					}
					i = i + 1;
				}
			}
			e = e + 1;
		}
	}
	return sheet;
}
`;

test "macro reflection: named shape validation accepts exactly declared keys" {
	for (const valid of [true, false]) {
		const object = valid ? '{ box: { width: 5.0, color: "red" } }' : '{ box: { widht: 5.0 } }';
		const result = compileToCWithStd(namedShapeMacro + "const sheet = createStyles(" + object + ");");
		assert result.ok == valid, object;
		if (!result.ok) assert result.error.contains("unknown style field"), result.error;
	}
}

test "macro reflection: unavailable named types are refused" {
	const result = compileToCWithStd(`
import { Node, NodeKind } from "std/meta";

export macro bad(x: Node): Node {
	const t = getTypeImpl(NoSuchTypeAnywhere);
	return x;
}

function main(): void {
	const v = bad(1);
}
`);
	assert !result.ok;
}

const explicitShapeMacro = `
import { Node, NodeKind, stringValue } from "std/meta";

interface User { name: string; age: int32; }
interface Point { x: int32; y: int32; }

export macro fieldsOfT(x: Node): Node {
	const t = getTypeArg();
	let names: string = "";
	if (t.kind === NodeKind.TypeObject) {
		let i = 0;
		while (i < t.typExprFieldNames.length) {
			if (i > 0) { names = names + ","; }
			names = names + t.typExprFieldNames[i];
			i = i + 1;
		}
	}
	if (names !== stringValue(x)) { error("type argument cache reused another shape", x); }
	return { kind: NodeKind.StringLiteral, line: x.line, column: x.column, value: names };
}
`;

test "macro reflection: each explicit type argument owns its expansion" {
	const result = compileToCWithStd(explicitShapeMacro + 'const a = fieldsOfT<User>("name,age"); const b = fieldsOfT<Point>("x,y"); const c = fieldsOfT<User>("name,age");');
	assert result.ok, result.ok ? "" : result.error;
}

test "macro reflection: absent explicit type arguments are refused" {
	assert !compileToCWithStd(explicitShapeMacro + 'const a = fieldsOfT("name,age");').ok;
}
