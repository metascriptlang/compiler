import { Node } from "std/meta";

export macro identity(mod: Node): Node {
	return mod;
}
