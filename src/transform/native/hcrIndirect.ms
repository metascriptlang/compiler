import { Node, NodeKind, ProgramData, createNode, SourceLocation } from "../../ast/node";
import { syntheticToken } from "../util";

export struct HcrIndirectModule {
	moduleId: string;
	symbols: string[];
}

export function lowerHcrIndirection(
	program: Node,
	own: HcrIndirectModule,
	modules: HcrIndirectModule[],
): Node {
	if (program == null || program.kind != NodeKind.Program) return program;
	const pd = program.data as ProgramData;
	const loc = program.location;
	const emitted: Node[] = [makeEmitStmt("/*INCLUDESECTION*/#include \"runtime/hcr.h\"", loc)];

	if (own.symbols.length > 0) {
		let table = `/*VARSECTION*/static void* const _ms_hcr_table[${own.symbols.length}] = {`;
		for (let i = 0; i < own.symbols.length; i += 1) {
			const symbol = own.symbols[i];
			table = table + (i > 0 ? ", " : " ") + (symbol != "" ? `(void*)&${symbol}` : "NULL");
		}
		emitted.push(makeEmitStmt(table + " };", loc));
		emitted.push(makeEmitStmt(
			`/*DATINITSECTION*/  msHcrPublish(${cString(own.moduleId)}, _ms_hcr_table, ${own.symbols.length});`,
			loc,
		));
	}

	for (let k = 0; k < modules.length; k += 1) {
		const target = modules[k];
		if (target.moduleId == own.moduleId || target.symbols.length == 0) continue;
		const handle = `_ms_hcr_m${k}`;
		emitted.push(makeEmitStmt(`/*VARSECTION*/static MsHcrHandle* ${handle};`, loc));
		emitted.push(makeEmitStmt(
			`/*DATINITSECTION*/  ${handle} = msHcrHandle(${cString(target.moduleId)});`,
			loc,
		));
		for (let slot = 0; slot < target.symbols.length; slot += 1) {
			const symbol = target.symbols[slot];
			if (symbol == "") continue;
			emitted.push(makeEmitStmt(
				`/*VARSECTION*/#define ${symbol} ((__typeof__(&${symbol}))${handle}->current[${slot}])`,
				loc,
			));
		}
	}

	if (emitted.length == 1) return program;
	for (const stmt of pd.programStmts) emitted.push(stmt);
	pd.programStmts = emitted;
	return program;
}

function cString(value: string): string {
	let out = "\"";
	for (let i = 0; i < value.length; i += 1) {
		const ch = value.charAt(i);
		if (ch == "\\" || ch == "\"") out = out + "\\";
		out = out + ch;
	}
	return out + "\"";
}

function makeEmitStmt(code: string, loc: SourceLocation): Node {
	const strNode = createNode(NodeKind.StringLiteral, { value: code }, syntheticToken(loc));
	const macroNode = createNode(
		NodeKind.MacroInvocation,
		{ macroName: "emit", macroArgs: [strNode], macroHasParens: true },
		syntheticToken(loc),
	);
	return createNode(NodeKind.ExprStmt, { expr: macroNode }, syntheticToken(loc));
}
