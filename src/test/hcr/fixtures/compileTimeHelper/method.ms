import { NodeKind, createNodeAt, makeLoc } from "std/meta";
import { describe } from "./shapes";

class Probe {
	run(): string {
		return describe(createNodeAt(NodeKind.Identifier, { name: "Point" }, makeLoc(1, 1)));
	}
}

console.log(new Probe().run());
