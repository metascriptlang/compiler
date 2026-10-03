import { Node } from "../ast/node";
import { ExportRegistry } from "../checker/context";
import { TransformContext } from "./context";

export function refineTypes(program: Node, _ctx: TransformContext, _registry: ExportRegistry): Node {
	return program;
}
