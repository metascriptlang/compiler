// @stdout: shallow=true impl=true nested=true array=true
import { Node, NodeKind, getType, getTypeImpl, sameType } from "std/meta";
struct Inner { n: int32; }
struct Outer { child: Inner; children: Inner[]; }
macro shape(x: Node): Node {
	const shallow = getType(x);
	const impl = getTypeImpl(x);
	const child = shallow.typExprFieldTypes[0];
	const implChild = impl.typExprFieldTypes[0];
	const nested = getTypeImpl(child);
	const array = getTypeImpl(shallow.typExprFieldTypes[1]);
	if (!sameType(child, array.typExprElement)) error("nested child identity differs", x);
	return { kind: NodeKind.StringLiteral, line: x.line, column: x.column,
		value: `shallow=${child.kind == NodeKind.Identifier} impl=${implChild.kind == NodeKind.Identifier} nested=${nested.kind == NodeKind.TypeObject} array=${array.typExprElement.kind == NodeKind.Identifier}` };
}
const value: Outer = { child: { n: 1 }, children: [{ n: 2 }] };
console.log(shape(value));
