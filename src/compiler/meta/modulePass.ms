import { Node, NodeKind, NodeFlag, ProgramData, ExportDeclData, ImportDeclData, createNodeAt } from "../../ast/node";
import { nodeKindName } from "../../ast/fieldspec";
import { CheckerContext, addError } from "../../checker/context";
import { registerApplyModulePasses } from "../../checker/checkerCallbacks";
import { modulePasses, modulePassExempt, ModulePass, ModulePassState } from "../../checker/prelude";
import { invokeMacro } from "./expand";

function importSignature(stmts: Node[]): string {
	const parts: string[] = [];
	for (const raw of stmts) {
		let stmt = raw;
		if (stmt.kind == NodeKind.ExportDecl) stmt = (stmt.data as ExportDeclData).exportedDecl;
		if (stmt == null || stmt.kind != NodeKind.ImportDecl) continue;
		const d = stmt.data as ImportDeclData;
		parts.push(`${raw.kind == NodeKind.ExportDecl ? "export " : ""}${d.importSource}:${d.importNames.join(",")}:${d.importAliases.join(",")}`);
	}
	return parts.join("\n");
}

function runModulePass(ctx: CheckerContext, program: Node, pass: ModulePass): void {
	const pd = program.data as ProgramData;
	const call = createNodeAt(NodeKind.MacroInvocation, { macroName: pass.macro, macroArgs: [program], macroHasParens: true }, program.location);
	call.flags = call.flags.incl(NodeFlag.BoundSym);
	call.resolvedSym = pass.sym;
	const out = invokeMacro(call, ctx);
	if (out == call) return;
	if (out.kind != NodeKind.Program) {
		addError(ctx, `module pass '${pass.macro}' must return the module it was given (a Program), got ${nodeKindName(out.kind)}`, 1, 1);
		return;
	}
	const stmts = (out.data as ProgramData).programStmts;
	if (importSignature(stmts) != importSignature(pd.programStmts)) {
		addError(ctx, `module pass '${pass.macro}' changed the imports of this module; imports are resolved before the pass runs, so a pass may not add, remove or rewrite them`, 1, 1);
		return;
	}
	pd.programStmts = stmts;
}

export function applyModulePasses(ctx: CheckerContext, program: Node): void {
	const passes = modulePasses();
	if (passes.length == 0 || program == null || program.kind != NodeKind.Program) return;
	if (ctx.modulePath == "" || modulePassExempt(ctx.modulePath)) return;
	for (const pass of passes) {
		match (pass.state) {
			ModulePassState.Bound => runModulePass(ctx, program, pass),
			ModulePassState.Broken => {},
			ModulePassState.Unbound => addError(ctx, `internal: module pass '${pass.macro}' from '${pass.entry}' is not bound while checking a module outside the globalImports closure`, 1, 1),
		};
	}
}

registerApplyModulePasses(applyModulePasses);
