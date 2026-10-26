// Parser context - the compilation's define table and a call's type argument

import { Node } from "../ast/node";
import { DefineTable, createDefineTable, definedValue, initDefines } from "../compiler/defines";
import { platform, arch } from "std/process";

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

// A parse no build seeded the defines for (an in-process check) runs as the host's debug build of
// `backend`, so a `when` in std picks the branch the module set it loads was written for.
export function parseAsBuildOf<T>(backend: string, run: () => T): T {
	if (definedValue(_parserDefines, "backend") != "") return run();
	const seeded = _parserDefines;
	const t = createDefineTable();
	initDefines(t, backend, platform, arch, "drc", 0);
	_parserDefines = t;
	try {
		return run();
	} finally {
		_parserDefines = seeded;
	}
}
