// The JS/wasm boundary in the editor: a hover section on an @wasm function and an inlay hint at each
// call that crosses. The manifest decides what crosses and why a declaration cannot; nothing here classifies.

import { Node, NodeKind, Symbol, SymbolFlag, CallExprData, ProgramData } from "../../../ast/node";
import { forEachChild } from "../../../ast/visitor";
import { ExtensionRegistry, CheckerContext, buildExportInfo } from "../../../checker/context";
import { hasFlag } from "../../../checker/symbol";
import { typeDisplayName } from "../../../checker/types";
import { BoundaryKind } from "../../wasmBoundary/boundaryKinds";
import { BoundaryFunction, BoundaryMode, BoundaryParam, Manifest, manifestFor } from "../../wasmBoundary/manifest";

export interface BoundaryHint {
	line: int32;
	col: int32;
	label: string;
}

function isWasmSym(sym: Symbol | null): boolean {
	return sym != null && hasFlag(sym!, SymbolFlag.Wasm);
}

function manifestOf(sym: Symbol): Manifest {
	const exported = buildExportInfo(sym, null as unknown as ExtensionRegistry, sym.modulePath, null as unknown as CheckerContext);
	return manifestFor(sym.modulePath, sym.modulePath, [exported], [sym.name]);
}

function crossing(kind: BoundaryKind, mode: BoundaryMode, resultSide: boolean): string {
	return match (kind) {
		BoundaryKind.I64 => "by value (BigInt)",
		BoundaryKind.U64 => "by value (BigInt)",
		BoundaryKind.String => resultSide ? "decoded from wasm memory" : "encoded (WTF-8) into wasm memory",
		BoundaryKind.Struct => resultSide ? "rebuilt from flattened fields" : "flattened into its fields",
		BoundaryKind.Vec => resultSide ? "copied out of wasm memory" : "copied into wasm memory",
		BoundaryKind.Span => mode == BoundaryMode.Shared ? "lent for the call, written back after it" : "lent for the call, read only",
		BoundaryKind.Callback => "borrowed for the call",
		_ => "by value",
	};
}

function paramLine(p: BoundaryParam, typeText: string): string {
	return `- \`${p.name}: ${typeText}\`: ${crossing(p.kind, p.mode, false)}${p.nullable ? ", nullable" : ""}`;
}

function functionLines(f: BoundaryFunction, sym: Symbol): string[] {
	const lines: string[] = [];
	const ft = sym.symbolType;
	for (let i = 0; i < f.params.length; i += 1) {
		const typeText = ft != null && i < ft.typeChildren.length ? typeDisplayName(ft.typeChildren[i]) : "";
		lines.push(paramLine(f.params[i], typeText));
	}
	if (f.result != BoundaryKind.Void) lines.push(`- result: ${crossing(f.result, BoundaryMode.Copied, true)}${f.resultNullable ? ", nullable" : ""}`);
	return lines;
}

function overloadSym(sym: Symbol, overloadIndex: int32): Symbol {
	return overloadIndex > 0 && overloadIndex - 1 < sym.overloads.length ? sym.overloads[overloadIndex - 1] : sym;
}

// `overloadAt` is the overload a call resolved to, or -1 when the hover names the whole function.
export function boundaryHoverSection(sym: Symbol | null, overloadAt: int32): string {
	if (sym == null || !isWasmSym(sym) && !sym!.overloads.some((o: Symbol): boolean => isWasmSym(o))) return "";
	const manifest = manifestOf(sym!);
	const lines: string[] = [`**JS/wasm boundary**: \`${sym!.name}\` runs in wasm when the JS build places it; a call from JS-side code crosses.`];
	for (const f of manifest.functions) {
		if (overloadAt >= 0 && f.overloadIndex != overloadAt) continue;
		if (manifest.functions.length > 1) lines.push(`Overload ${f.overloadIndex}:`);
		for (const line of functionLines(f, overloadSym(sym!, f.overloadIndex))) lines.push(line);
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
		_ => 0,
	};
}

function costLabel(p: BoundaryParam): string {
	return match (p.kind) {
		BoundaryKind.Vec => "copy Vec",
		BoundaryKind.Span => "lend Span",
		BoundaryKind.Struct => "flatten struct",
		BoundaryKind.String => "encode string",
		BoundaryKind.Callback => "borrow callback",
		_ => "",
	};
}

function hintLabel(f: BoundaryFunction): string {
	let heaviest: BoundaryParam | null = null;
	for (const p of f.params) {
		if (costRank(p) > 0 && (heaviest == null || costRank(p) > costRank(heaviest!))) heaviest = p;
	}
	return heaviest == null ? "⇄ wasm" : `⇄ wasm: ${costLabel(heaviest!)}`;
}

function collect(node: Node | null, startLine: int32, endLine: int32, out: BoundaryHint[]): void {
	if (node == null) return;
	// wasm-placed code is the other side of the boundary: its calls to a sibling do not cross
	if (node.kind == NodeKind.FunctionDecl && isWasmSym(node.resolvedSym)) return;
	if (node.kind == NodeKind.CallExpr) {
		const cd = node.data as CallExprData;
		const callee = cd.callee;
		const sym = callee != null && callee.kind == NodeKind.Identifier ? callee.resolvedSym : null;
		if (sym != null && callee!.location.line >= startLine && callee!.location.line <= endLine && (isWasmSym(sym) || sym!.overloads.some((o: Symbol): boolean => isWasmSym(o)))) {
			const overloadIndex = cd.resolvedOverloadIdx > 0 ? cd.resolvedOverloadIdx as int32 : 0;
			for (const f of manifestOf(sym!).functions) {
				if (f.overloadIndex == overloadIndex) out.push({ line: callee!.location.line, col: callee!.location.column, label: hintLabel(f) });
			}
		}
	}
	forEachChild(node, (child: Node): void => collect(child, startLine, endLine, out));
}

export function collectBoundaryHints(program: Node, startLine: int32, endLine: int32): BoundaryHint[] {
	const out: BoundaryHint[] = [];
	for (const stmt of (program.data as ProgramData).programStmts) collect(stmt, startLine, endLine, out);
	return out;
}
