// bug052 — macro body cannot read node.nodeType (type-AST) fields: A4 typeToValue read path
//
// Symptom:    a macro reading `t.nodeType.typExprFieldNames` (the wire format
//             mapTypeToAst already ships to the VM) fails the engine typecheck
//             with "Property 'typExprFieldNames' does not exist on type 'Type'".
//             The static decl std/meta Node.nodeType: Type describes a shape
//             the VM never delivers — runtime hands macros a type-AST Node
//             (TypeObject/TypeUnion/TypeArray/...), so every Node-shaped flat
//             read is rejected while the runtime path works fine.
//
// Contract:   node.nodeType types as Node in macro bodies; flat reads on it
//             resolve per the NodeData unique-field-name DU rule
//             (engineNodeVirtualProp), same as reads on the node itself.

import { compileToCWithStd } from "../helpers";

const srcFields = `
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
	return { kind: NodeKind.StringLiteral, line: t.line, column: t.column, value: names };
}

function main(): void {
	const u: User = { name: "a", age: 3 };
	const s: string = fieldsOf(u);
	console.log(s);
}
`;

test "bug052: macro reads interface fields via nodeType and emits them" {
	const c = compileToCWithStd(srcFields);
	assert c.ok;
	assert c.value.indexOf("name:string,age:int32", 0) >= 0;
}

const srcUnion = `
import { Node, NodeKind } from "std/meta";

type Shape = { kind: "circle", r: number } | { kind: "square", s: number };

export macro unionInfo(t: Node): Node {
	let tt = t.nodeType;
	if (tt.kind === NodeKind.TypeGeneric) {
		tt = tt.typExprArgs[0];
	}
	let desc: string = "members=";
	if (tt.kind === NodeKind.TypeUnion) {
		desc = desc + tt.typExprMembers.length + " disc=" + tt.discFieldName;
	}
	return { kind: NodeKind.StringLiteral, line: t.line, column: t.column, value: desc };
}

function main(): void {
	const sh: Shape = { kind: "circle", r: 5.0 };
	const s: string = unionInfo(sh);
	console.log(s);
}
`;

test "bug052: macro reads union members + disc metadata via nodeType" {
	const c = compileToCWithStd(srcUnion);
	assert c.ok;
	assert c.value.indexOf("members=2", 0) >= 0;
}

// Demo "đường B" — a macro validates object-literal keys against an interface
// read via nodeType, with its own error message (the createStyles rewrite
// shape: no styleOf delegation, no hardcoded field list). The interface shape
// comes from a witness param (decode.ms's witness.nodeType pattern) because a
// bare object-literal argument carries no contextual type before expansion.
const srcDemo = `
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

test "bug052 demo B: macro rejects unknown literal keys with its own message" {
	const c = compileToCWithStd(srcDemo);
	assert !c.ok;
	assert c.error.indexOf("unknown key 'colr'", 0) >= 0;
	assert c.error.indexOf("available: width, color", 0) >= 0;
}

// Representation guard: a type-AST Node read from nodeType must be a Node VALUE
// (Ref<Node>), not the peeled Struct — otherwise handing it to any function
// taking `Node` fails with the nonsensical "got Node, expected Node".
const srcPassToHelper = `
import { Node, NodeKind } from "std/meta";

interface User { name: string; age: int32; }

export function describeType(n: Node): string {
	return "k" + n.kind;
}

export macro viaHelper(t: Node): Node {
	let tt = t.nodeType;
	if (tt.kind === NodeKind.TypeGeneric) {
		tt = tt.typExprArgs[0];
	}
	const d: string = describeType(tt);
	return { kind: NodeKind.StringLiteral, line: t.line, column: t.column, value: d };
}

function main(): void {
	const u: User = { name: "a", age: 3 };
	const s: string = viaHelper(u);
	console.log(s);
}
`;

test "bug052: nodeType flows into a Node-typed parameter" {
	const c = compileToCWithStd(srcPassToHelper);
	assert c.ok;
}
