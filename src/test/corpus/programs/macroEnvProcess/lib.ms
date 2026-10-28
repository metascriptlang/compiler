import { Node, NodeKind, createNodeAt } from "std/meta";
import { env, findOnPath } from "std/process";

export macro pathLength(at: Node): Node {
	return createNodeAt(NodeKind.StringLiteral, { value: env.get("PATH").length.toString() }, at.location);
}

export macro unsetVar(at: Node): Node {
	return createNodeAt(NodeKind.StringLiteral, { value: "[" + env.get("MS_LANE_F_NEVER_SET") + "]" }, at.location);
}

export macro foundOnPath(at: Node): Node {
	return createNodeAt(NodeKind.StringLiteral, { value: findOnPath("msc") }, at.location);
}
