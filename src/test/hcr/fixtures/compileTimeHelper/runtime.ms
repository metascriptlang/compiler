import { NodeKind, createNodeAt, makeLoc } from "std/meta";
import { describe } from "./shapes";

console.log(describe(createNodeAt(NodeKind.Identifier, { name: "Point" }, makeLoc(1, 1))));
