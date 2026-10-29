import { Node, NodeKind, ProgramData } from "../../ast/node";
import { isWasmPlacementStmt } from "../../checker/decoratorHelpers";

export function hasWasmPlacement(program: Node): boolean {
	if (program == null || program.kind != NodeKind.Program) return false;
	for (const stmt of (program.data as ProgramData).programStmts) {
		if (isWasmPlacementStmt(stmt)) return true;
	}
	return false;
}

export function placedModules(paths: string[], programs: Node[]): string[] {
	if (paths.length != programs.length) throw new Error(`internal: placedModules got ${paths.length} paths and ${programs.length} programs`);
	const placed: string[] = [];
	for (let i = 0; i < paths.length; i += 1) {
		if (hasWasmPlacement(programs[i])) placed.push(paths[i]);
	}
	return placed;
}
