import { Node } from "std/meta";

export macro passThrough(value: Node): Node {
	return value;
}

export enum Shade { Light, Dark }
