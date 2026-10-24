import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { checkProgramWithRegistry, preludeContextFor } from "../../checker/checkPass";
import { ExportRegistry } from "../../checker/context";
import { transformProgram } from "../../transform/index";
import { Node, NodeKind, Symbol, MemberExprData } from "../../ast/node";
import { Module, ModuleGraph } from "../../module/graph";
import { forEachChild } from "../../ast/visitor";
import { resetBuildState } from "../../compiler/buildSession";

function transformedProgram(source: string, jsBackend: boolean): Node {
	resetBuildState();
	const prelude = preludeContextFor("", jsBackend ? ".jms" : ".cms");
	const pr = parseSource(source);
	if (!pr.ok) throw new Error("internal: test source does not parse");
	const ctx = checkProgramWithRegistry(pr.value, null as unknown as ExportRegistry, null as unknown as ModuleGraph, null as unknown as Module, prelude);
	return transformProgram(pr.value, ctx, jsBackend);
}

function isLoweringName(name: string): boolean {
	return name == "_envP" || name == "$state" || name == "$curExc" || name == "this"
		|| name.startsWith("_env") || name.startsWith("_self") || name.startsWith("_reach")
		|| name.startsWith("__aw_") || name.startsWith("$result_") || name.startsWith("$await_");
}

function noteSym(sym: Symbol | null, seen: Symbol[], bare: string[]): void {
	if (sym == null || !isLoweringName(sym.name) || seen.includes(sym)) return;
	seen.push(sym);
	if (sym.item <= 0) bare.push(sym.name);
}

function isResultTempMember(n: Node): boolean {
	if (n.kind != NodeKind.MemberExpr) return false;
	const obj = (n.data as MemberExprData).object;
	return obj.resolvedSym != null && obj.resolvedSym.name.startsWith("$result_");
}

function walkSyms(n: Node | null, seen: Symbol[], bare: string[]): void {
	if (n == null) return;
	noteSym(n.resolvedSym, seen, bare);
	if (isResultTempMember(n) && n.resolvedSym != null && n.resolvedSym.item <= 0) bare.push(n.resolvedSym.name);
	if (n.paramSyms != null) {
		for (const p of n.paramSyms) noteSym(p, seen, bare);
	}
	forEachChild(n, (c: Node): void => { walkSyms(c, seen, bare); });
}

function mintedNames(source: string, jsBackend: boolean): string {
	const seen: Symbol[] = [];
	const bare: string[] = [];
	walkSyms(transformedProgram(source, jsBackend), seen, bare);
	const names: string[] = [];
	for (const s of seen) names.push(s.name);
	return (bare.length > 0 ? `NO-IDENTITY ${bare.join(" ")} | ` : "") + names.join(" ");
}

test "loweredSymbolIdentity: the env parameter and env variable of a lifted closure carry an item" {
	const source = "function userCounter(): number { let n = 0; const bump = (): number => { n = n + 1; return n; }; bump(); return bump(); }";
	const names = mintedNames(source, false);
	assert !names.startsWith("NO-IDENTITY") && names.includes("_envP"), names;
	assert names.includes("_env"), names;
}

test "loweredSymbolIdentity: a try temp and the result fields read from it carry an item on both backends" {
	const source = "function userHalf(): Result<number, string> { return Result.ok(1); }\nfunction userTry(): Result<number, string> { const v = try userHalf(); return Result.ok(v); }";
	for (const js of [false, true]) {
		const names = mintedNames(source, js);
		assert !names.startsWith("NO-IDENTITY") && names.includes("$result_"), names;
	}
}

test "loweredSymbolIdentity: a synthesized constructor's receiver carries an item" {
	const source = "class UserBox { n: number = 1; }\nfunction userMake(): UserBox { return new UserBox(); }";
	const names = mintedNames(source, false);
	assert !names.startsWith("NO-IDENTITY") && names.includes("this"), names;
}
