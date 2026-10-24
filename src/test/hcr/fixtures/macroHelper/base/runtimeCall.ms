import { Node } from "std/meta";
import { reload } from "std/hcr";
import { arity } from "./tools";

function node(): Node {
	return null as unknown as Node;
}

reload();
console.log(arity(node()));
