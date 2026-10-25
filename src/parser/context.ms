// Parser context - the cursor and angle scanners under one name, and the compilation's define table

import { Node } from "../ast/node";
import { DefineTable, createDefineTable } from "../compiler/defines";

export * from "./cursor";
export * from "./generics";

export function findCallTypeArg(node: Node): string {
	return node.typeArg;
}

// ===== Conditional-compilation defines =====
// The table the `when` chain is resolved against (src/compiler/defines.ms). This is build CONFIGURATION owned by the driver, not
// per-parse state that must not leak between files. The driver sets it once per compilation; tests set and reset it explicitly.
let _parserDefines: DefineTable = createDefineTable();

export function setParserDefines(t: DefineTable): void { _parserDefines = t; }

export function getParserDefines(): DefineTable { return _parserDefines; }

export function resetParserDefines(): void { _parserDefines = createDefineTable(); }
