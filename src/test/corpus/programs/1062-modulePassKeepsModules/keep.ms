import { Node } from "std/meta";

export macro keepModule(mod: Node): Node {
	return mod;
}
