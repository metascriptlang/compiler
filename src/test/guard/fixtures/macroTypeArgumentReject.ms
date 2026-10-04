import { Node } from "std/meta";

export macro refuse(value: Node): Node {
	const shape = getTypeArg();
	error("the explicit type argument is refused", shape);
	return value;
}

export macro refuseField(value: Node): Node {
	const shape = getTypeArg();
	error("the explicit type field is refused", shape.typExprFieldTypes[0]);
	return value;
}
