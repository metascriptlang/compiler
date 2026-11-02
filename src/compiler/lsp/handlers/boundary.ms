// The JS/wasm boundary in the editor: a hover section on an @wasm function and
// an inlay hint at each call that crosses. The manifest decides what crosses
// and why a declaration cannot; nothing here classifies.

import {
	Node, NodeKind, Symbol, SymbolFlag, CallExprData, ProgramData,
} from "../../../ast/node";
import { forEachChild } from "../../../ast/visitor";
import { CheckerContext, buildExportInfo } from "../../../checker/context";
import { wasmReachedRoutines } from "../../../checker/sendable";
import { hasFlag } from "../../../checker/symbol";
import { typeDisplayName } from "../../../checker/types";
import { BoundaryKind } from "../../wasmBoundary/boundaryKinds";
import {
	BoundaryFunction, BoundaryMode, BoundaryParam, Manifest, manifestFor,
} from "../../wasmBoundary/manifest";

export interface BoundaryHint {
	line: int32;
	col: int32;
	label: string;
}

function isWasmSym(sym: Symbol | null): boolean {
	return sym != null && hasFlag(sym!, SymbolFlag.Wasm);
}

function placesWasm(sym: Symbol): boolean {
	return isWasmSym(sym) || sym.overloads.some(isWasmSym);
}

function manifestOf(ctx: CheckerContext, sym: Symbol): Manifest {
	const exported = buildExportInfo(
		sym, ctx.extensionRegistry, sym.modulePath, ctx,
	);
	return manifestFor(sym.modulePath, ctx.modulePath, [exported], [sym.name]);
}

function crossing(
	kind: BoundaryKind, mode: BoundaryMode, resultSide: boolean,
): string {
	return match (kind) {
		BoundaryKind.Bool
			| BoundaryKind.I8
			| BoundaryKind.I16
			| BoundaryKind.I32
			| BoundaryKind.U8
			| BoundaryKind.U16
			| BoundaryKind.U32
			| BoundaryKind.F32
			| BoundaryKind.F64
			| BoundaryKind.Void => "by value",
		BoundaryKind.I64 | BoundaryKind.U64 => "by value (BigInt)",
		BoundaryKind.String => resultSide
			? "decoded from wasm memory"
			: "encoded (WTF-8) into wasm memory",
		BoundaryKind.Struct => resultSide
			? "rebuilt from flattened fields"
			: "flattened into its fields",
		BoundaryKind.Vec => resultSide
			? "copied out of wasm memory"
			: "copied into wasm memory",
		BoundaryKind.Span => mode == BoundaryMode.Shared
			? "lent for the call, written back after it"
			: "lent for the call, read only",
		BoundaryKind.Callback => "borrowed for the call",
	};
}

function nullableNote(nullable: boolean): string {
	return nullable ? ", nullable" : "";
}

function paramLine(p: BoundaryParam, typeText: string): string {
	const how = crossing(p.kind, p.mode, false);
	return `- \`${p.name}: ${typeText}\`: ${how}${nullableNote(p.nullable)}`;
}

function functionLines(f: BoundaryFunction, sym: Symbol): string[] {
	const lines: string[] = [];
	const ft = sym.symbolType;
	for (let i = 0; i < f.params.length; i += 1) {
		const known = ft != null && i < ft.typeChildren.length;
		const typeText = known ? typeDisplayName(ft!.typeChildren[i]) : "";
		lines.push(paramLine(f.params[i], typeText));
	}
	if (f.result != BoundaryKind.Void) {
		const how = crossing(f.result, BoundaryMode.Copied, true);
		lines.push(`- result: ${how}${nullableNote(f.resultNullable)}`);
	}
	return lines;
}

function overloadSym(sym: Symbol, overloadIndex: int32): Symbol {
	const at = overloadIndex - 1;
	return at >= 0 && at < sym.overloads.length ? sym.overloads[at] : sym;
}

// `overloadAt` is the overload a call resolved to, or -1 when the hover names
// the whole function.
export function boundaryHoverSection(
	ctx: CheckerContext, sym: Symbol | null, overloadAt: int32,
): string {
	if (sym == null || !placesWasm(sym!)) return "";
	const manifest = manifestOf(ctx, sym!);
	const lines: string[] = [
		`**JS/wasm boundary**: \`${sym!.name}\` runs in wasm when the JS build `
			+ "places it; a call from JS-side code crosses.",
	];
	for (const f of manifest.functions) {
		if (overloadAt >= 0 && f.overloadIndex != overloadAt) continue;
		if (manifest.functions.length > 1) {
			lines.push(`Overload ${f.overloadIndex}:`);
		}
		for (const line of functionLines(f, overloadSym(sym!, f.overloadIndex))) {
			lines.push(line);
		}
	}
	for (const e of manifest.errors) lines.push(`- cannot cross: ${e.message}`);
	return lines.join("\n");
}

function costRank(p: BoundaryParam): int32 {
	return match (p.kind) {
		BoundaryKind.Vec => 5,
		BoundaryKind.Span => 4,
		BoundaryKind.Struct => 3,
		BoundaryKind.String => 2,
		BoundaryKind.Callback => 1,
		BoundaryKind.Bool
			| BoundaryKind.I8
			| BoundaryKind.I16
			| BoundaryKind.I32
			| BoundaryKind.U8
			| BoundaryKind.U16
			| BoundaryKind.U32
			| BoundaryKind.I64
			| BoundaryKind.U64
			| BoundaryKind.F32
			| BoundaryKind.F64
			| BoundaryKind.Void => 0,
	};
}

function costLabel(p: BoundaryParam): string {
	return match (p.kind) {
		BoundaryKind.Vec => "copy Vec",
		BoundaryKind.Span => "lend Span",
		BoundaryKind.Struct => "flatten struct",
		BoundaryKind.String => "encode string",
		BoundaryKind.Callback => "borrow callback",
		BoundaryKind.Bool
			| BoundaryKind.I8
			| BoundaryKind.I16
			| BoundaryKind.I32
			| BoundaryKind.U8
			| BoundaryKind.U16
			| BoundaryKind.U32
			| BoundaryKind.I64
			| BoundaryKind.U64
			| BoundaryKind.F32
			| BoundaryKind.F64
			| BoundaryKind.Void => "",
	};
}

function hintLabel(f: BoundaryFunction): string {
	let heaviest: BoundaryParam | null = null;
	for (const p of f.params) {
		if (costRank(p) == 0) continue;
		if (heaviest == null || costRank(p) > costRank(heaviest!)) heaviest = p;
	}
	return heaviest == null ? "⇄ wasm" : `⇄ wasm: ${costLabel(heaviest!)}`;
}

function isReached(node: Node, reached: Node[]): boolean {
	const isRoutine = node.kind == NodeKind.FunctionDecl
		|| node.kind == NodeKind.MethodDecl;
	const sym = node.resolvedSym;
	return isRoutine && sym != null && reached.includes(sym!.declNode!);
}

function calleeSym(call: CallExprData): Symbol | null {
	const callee = call.callee;
	if (callee == null || callee.kind != NodeKind.Identifier) return null;
	return callee.resolvedSym;
}

function collect(
	ctx: CheckerContext,
	node: Node | null,
	inWasm: Node[],
	lines: int32[],
	out: BoundaryHint[],
): void {
	if (node == null) return;
	if (isReached(node, inWasm)) return;
	if (node.kind == NodeKind.CallExpr) {
		const cd = node.data as CallExprData;
		const sym = calleeSym(cd);
		const at = cd.callee!.location;
		if (sym != null && at.line >= lines[0] && at.line <= lines[1]
				&& placesWasm(sym!)) {
			const resolved = cd.resolvedOverloadIdx;
			const idx = resolved > 0 ? resolved as int32 : 0;
			for (const f of manifestOf(ctx, sym!).functions) {
				if (f.overloadIndex != idx) continue;
				out.push({ line: at.line, col: at.column, label: hintLabel(f) });
			}
		}
	}
	forEachChild(node, (child: Node): void => {
		collect(ctx, child, inWasm, lines, out);
	});
}

// A routine wasm code reaches is compiled into wasm, so its calls to an @wasm
// function stay inside wasm and do not cross.
export function collectBoundaryHints(
	ctx: CheckerContext, program: Node, startLine: int32, endLine: int32,
): BoundaryHint[] {
	const out: BoundaryHint[] = [];
	const inWasm = wasmReachedRoutines(ctx, program);
	for (const stmt of (program.data as ProgramData).programStmts) {
		collect(ctx, stmt, inWasm, [startLine, endLine], out);
	}
	return out;
}
