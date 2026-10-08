import { Node as DomNode } from "./foreign";
import { pick as first } from "./first";
import { pick as second } from "./second";

export function textOf(node: DomNode): string { return node.textContent; }

first(0);
export function foreignFirst(): number { return first(0); }
export function foreignSecond(): number { return second(0); }
