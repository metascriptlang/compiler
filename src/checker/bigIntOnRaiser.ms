import { Node, NodeKind, SymbolKind, Type, TypeKind } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { CheckerContext, CheckerError, addError, hasErrors } from "./context";
import { peelToRepr } from "./types";
import { checkProgram } from "./checkPass";
import { parseSource } from "../parser/statements/validation";

export const RAISER_NO_BIGINT_MSG: string = "bigint is not supported on the Raiser VM: it has no arbitrary-precision integer";

function isBigInt(t: Type | null): boolean {
	const r = peelToRepr(t);
	if (r == null) return false;
	if (r.kind == TypeKind.BigInt) return true;
	if (r.kind != TypeKind.Union) return false;
	for (const member of r.typeChildren) {
		if (isBigInt(member)) return true;
	}
	return false;
}

export function carriesBigInt(t: Type | null): boolean {
	if (isBigInt(t)) return true;
	const r = peelToRepr(t);
	if (r == null || r.kind != TypeKind.Function) return false;
	if (isBigInt(r.typeReturn)) return true;
	for (const param of r.typeChildren) {
		if (isBigInt(param)) return true;
	}
	return false;
}

function holdsValue(kind: SymbolKind): boolean {
	return kind == SymbolKind.Variable || kind == SymbolKind.Function || kind == SymbolKind.Parameter
		|| kind == SymbolKind.Property || kind == SymbolKind.Method;
}

function siteType(node: Node): Type | null {
	if (node.nodeType != null) return node.nodeType;
	const sym = node.resolvedSym;
	return sym != null && holdsValue(sym.symbolKind) ? sym.symbolType : null;
}

function collect(node: Node, out: Node[]): void {
	if (node.kind == NodeKind.TypeAliasDecl) return;
	if (carriesBigInt(siteType(node))) {
		out.push(node);
		return;
	}
	forEachChild(node, (child: Node): void => { collect(child, out); });
}

export function refuseBigIntOnRaiser(ctx: CheckerContext, program: Node): void {
	const sites: Node[] = [];
	collect(program, sites);
	for (const site of sites) addError(ctx, RAISER_NO_BIGINT_MSG, site.location.line, site.location.column);
}

function refusedLines(src: string): string {
	const pr = parseSource(src);
	if (!pr.ok) return "parse error";
	const ctx = checkProgram(pr.value);
	if (hasErrors(ctx)) return "check error: " + ctx.errors[0].message;
	refuseBigIntOnRaiser(ctx, pr.value);
	return ctx.errors.map((e: CheckerError): string => `${e.line}`).join(" ");
}

test "a bigint literal, a conversion into bigint and each bigint operand of a comparison are refused on the Raiser at its site" {
	const lines = refusedLines("function u(v: uint64): uint64 { return v; }\n"
		+ "const a = 5n;\n"
		+ "const n = Number(u(18446744073709551615) as bigint);\n"
		+ "const k = a > 2n;\n");
	assert lines == "2 3 4 4", lines;
}

test "a bigint parameter or return is refused at its declaration even when nothing calls it" {
	const lines = refusedLines("function take(x: bigint): int32 { return 1; }\n"
		+ "function give(n: int32): bigint { return n as bigint; }\n"
		+ "const f: (v: bigint) => int32 = take;\n");
	assert lines == "1 2 3", lines;
}

test "an expression is refused once, not once per bigint operand inside it" {
	assert refusedLines("const s = `${5n + 3n * 2n}`;\n") == "1";
}

test "a program that holds no bigint value is not refused on the Raiser" {
	assert refusedLines("type Big = bigint;\nconst n = sizeof(bigint);\nconst t = typeof 1 === \"bigint\";\nconst w: uint64 = 18446744073709551615;\n") == "";
}
