// Printer Callbacks — breaks circular dependency between sub-printers
// Same pattern as parser/statements/callbacks.ms.

import { Node } from "../../../ast/node";
import { FormatOptions } from "../options";
import { Doc, docNil } from "../doc";

export type NodePrinterFn = (node: Node, options: FormatOptions) => Doc;

let nodePrinterFn: NodePrinterFn = (node: Node, options: FormatOptions): Doc => {
	return docNil();
};

export function registerNodePrinter(fn: NodePrinterFn): void {
	nodePrinterFn = fn;
}

export function callPrintNode(node: Node, options: FormatOptions): Doc {
	return nodePrinterFn(node, options);
}
