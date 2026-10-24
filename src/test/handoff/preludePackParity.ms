// The pack a build reads back holds what the fresh check of the std tree produced: every scope
// symbol with its type, flags and overloads, its declaration tree down to the macro bodies, and
// the tables the checker consults (extensions, interfaces, module scopes, compiler functions).
import { env } from "std/process";
import { join } from "std/fs/path";
import { readFile, writeFile, removeAll } from "std/fs";
import { Symbol, Type, NodeKind } from "../../ast/node";
import { pkDumpNode } from "../../ast/fieldspec";
import { CheckerContext } from "../../checker/context";
import { identName } from "../../checker/idents";
import { checkPreludeFromSource } from "../../checker/checkPass";
import { writePreludePack, tryLoadPreludePack, packRoot } from "../../checker/preludePack";
import { resolveRuntimeDir } from "../../utils/path";

const STAMP = "pack-parity-stamp";
const KEY = "pack-parity-key";

function typeText(t: Type | null, depth: int32): string {
	if (t == null) return "null";
	let s = `${t.kind as int32}:${t.typeFlags as uint32}:${t.typeValue}:${t.callConv as int32}:${t.typeName}:${t.typeNames != null ? t.typeNames.join("|") : ""}`;
	if (depth == 0) return s;
	s = s + "(";
	if (t.typeChildren != null) {
		for (const c of t.typeChildren) s = s + typeText(c, depth - 1) + ",";
	}
	s = s + `)ret=${typeText(t.typeReturn, depth - 1)}extra=${typeText(t.typeExtra, depth - 1)}sym=${t.sym != null ? t.sym.name : "-"}`;
	return s;
}

function symText(s: Symbol): string {
	let text = `${s.name}|${s.symbolKind as int32}|${s.state as int32}|${s.symFlags as uint32}|${s.modulePath}|${s.nativeName}|${s.exportName}|${s.builtinKind}|${s.headerPath}|${s.jsModulePath}|${s.overloadIdx}|${s.disamb}|${s.mutatedParams}|${s.duVariantSlot}|${s.location.line}:${s.location.column}`;
	text = text + `|t=${typeText(s.symbolType, 3)}|tps=`;
	if (s.typeParams != null) {
		for (const tp of s.typeParams) text = text + typeText(tp, 1) + ";";
	}
	text = text + "|ovl=";
	if (s.overloads != null) {
		for (const o of s.overloads) text = text + `${o.name}/${o.symFlags as uint32};`;
	}
	text = text + "|static=";
	if (s.staticFields != null) {
		for (const f of s.staticFields) text = text + `${f.name};`;
	}
	text = text + `|owner=${s.staticOwner != null ? s.staticOwner.name : "-"}|decl=${pkDumpNode(s.declNode)}|dp=`;
	if (s.defaultParams != null) {
		for (const d of s.defaultParams) text = text + pkDumpNode(d) + ";";
	}
	return text;
}

function namesOf(members: Symbol[]): string {
	let text = "";
	for (const m of members) text = text + `${m.name}/${m.symFlags as uint32};`;
	return text;
}

function absentLocationAsZero(text: string): string {
	return text.replaceAll("L-;", "L0,0,0,0;");
}

function sameScopeText(ctx: CheckerContext): string[] {
	const rows: string[] = [];
	const scope = ctx.table.current.symbols;
	for (const id of scope.keys()) {
		const s = scope.get(id);
		if (s != null) rows.push(`${identName(ctx.table.identCache, id)}=>${absentLocationAsZero(symText(s))}`);
	}
	rows.sort();
	return rows;
}

function tableRows(ctx: CheckerContext): string[] {
	const rows: string[] = [];
	if (ctx.extensionRegistry != null) {
		for (const e of ctx.extensionRegistry.methods) rows.push(`ext|${e.methodName}|${e.sourcePath}|${e.isStatic}|${e.scopeDepth as int32}|${e.sym != null ? e.sym.name : "-"}`);
	}
	for (const spec of ctx.preludeInterf.keys()) {
		const members = ctx.preludeInterf.get(spec);
		rows.push(`interf|${spec}|${members != null ? namesOf(members) : "-"}`);
	}
	for (const path of ctx.preludeModuleScopes.keys()) {
		const members = ctx.preludeModuleScopes.get(path);
		rows.push(`scope|${path}|${members != null ? members.length : -1}`);
		if (members != null) {
			for (const m of members) rows.push(`member|${absentLocationAsZero(symText(m))}`);
		}
	}
	for (const name of ctx.compilerFuncs.keys()) {
		const s = ctx.compilerFuncs.get(name);
		rows.push(`cfn|${name}|${s != null ? s.name : "-"}`);
	}
	for (const path of ctx.ownModules) rows.push(`own|${path}`);
	rows.push(`counts|${ctx.importSet.size}|${ctx.interfSet.size}|${ctx.interf.length}|${ctx.converterTargetTypes.size}|${ctx.preludeExports.size}`);
	rows.push(`dir|${ctx.includeDirectives}|${ctx.compilerFlags}|${ctx.compileDirectives}`);
	rows.sort();
	return rows;
}

function firstMismatch(fresh: string[], loaded: string[]): string {
	if (fresh.length != loaded.length) return `row count ${fresh.length} against ${loaded.length}`;
	for (let i = 0; i < fresh.length; i += 1) {
		if (fresh[i] == loaded[i]) continue;
		let at = 0;
		while (at < fresh[i].length && at < loaded[i].length && fresh[i].charCodeAt(at) == loaded[i].charCodeAt(at)) at += 1;
		const from = at > 80 ? at - 80 : 0;
		return `row ${i} differs at ${at}: ${fresh[i].slice(from, at + 80)} against ${loaded[i].slice(from, at + 80)}`;
	}
	return "";
}

test "a pack read back holds the symbols, types, declaration trees and tables of the fresh prelude check" {
	const prevHome = env.get("HOME");
	env.set("HOME", `out/test/preludePackParity.${performance.now()}`);
	try {
		assert packRoot() != "";
		const fresh = checkPreludeFromSource(join(resolveRuntimeDir(), "std"), ".rms");
		writePreludePack(KEY, STAMP, fresh);
		const path = `${packRoot()}/${KEY}.pk`;
		const loaded = tryLoadPreludePack(KEY, STAMP);
		assert loaded != null, `the pack at ${path} did not load`;
		assert fresh.table.current.symbols.size > 100;
		const scopeDiff = firstMismatch(sameScopeText(fresh), sameScopeText(loaded));
		assert scopeDiff == "", scopeDiff;
		const tableDiff = firstMismatch(tableRows(fresh), tableRows(loaded));
		assert tableDiff == "", tableDiff;

		const text = try readFile(path) catch "";
		const lines = text.split("\n");
		let swapped = false;
		for (let i = 0; i < lines.length; i += 1) {
			if (!lines[i].startsWith("N\t")) continue;
			const f = lines[i].split("\t");
			if (f.length < 20 || f[2] != `${NodeKind.BinaryExpr as int32}`) continue;
			const tmp = f[18];
			f[18] = f[19];
			f[19] = tmp;
			if (f[18] == f[19]) continue;
			lines[i] = f.join("\t");
			swapped = true;
		}
		assert swapped, "no binary-expression row to damage";
		writeFile(path, lines.join("\n"));
		const damaged = tryLoadPreludePack(KEY, STAMP);
		assert damaged != null;
		const damage = firstMismatch(sameScopeText(fresh), sameScopeText(damaged)) + firstMismatch(tableRows(fresh), tableRows(damaged));
		assert damage != "", "a pack with two operands swapped matched the fresh check";
	} finally {
		const home = env.get("HOME");
		if (prevHome == "") env.delete("HOME");
		else env.set("HOME", prevHome);
		removeAll(home);
	}
}
