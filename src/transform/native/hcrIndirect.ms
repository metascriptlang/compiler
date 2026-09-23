import { Node, NodeKind, ProgramData, createNode, SourceLocation } from "../../ast/node";
import { syntheticToken } from "../util";

export struct HcrImport {
	moduleId: string;
	abiKey: string;
}

export struct HcrIndirectModule {
	moduleId: string;
	symbols: string[];
	typeInfos: string[];
	abiKey: string;
	imports: HcrImport[];
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
	emitted.push(makeEmitStmt(`MS_HCR_EXPORT const char* HcrAbiKey000(void) { return ${cString(own.abiKey)}; }`, loc));
	emitted.push(makeEmitStmt(importsFunction(own), loc));

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

	let typeSlot = 0;
	for (const target of modules) {
		for (const typeName of target.typeInfos) {
			const pointer = `_ms_hcr_ti${typeSlot}`;
			typeSlot += 1;
			emitted.push(makeEmitStmt(`/*VARSECTION*/msTypeInfo* ${pointer};`, loc));
			emitted.push(makeEmitStmt(`/*VARSECTION*/#define ${typeName}TypeInfo (*${pointer})`, loc));
			emitted.push(makeEmitStmt(
				`/*DATINITSECTION*/  ${pointer} = (msTypeInfo*)msHcrTypeInfo(${cString(target.moduleId)}, ${cString(typeName)});`,
				loc,
			));
		}
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

	for (const stmt of pd.programStmts) emitted.push(stmt);
	pd.programStmts = emitted;
	return program;
}

function importsFunction(own: HcrIndirectModule): string {
	let entries = "";
	for (const entry of own.imports) entries = entries + `${cString(entry.moduleId)}, ${cString(entry.abiKey)}, `;
	return `MS_HCR_EXPORT const char* const* HcrImports000(void) { static const char* const imports[] = { ${entries}NULL }; return imports; }`;
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
