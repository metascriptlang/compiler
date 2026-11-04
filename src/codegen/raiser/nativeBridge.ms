import { Symbol, Type, TypeKind } from "../../ast/node";
import { stdModuleName } from "../../module/tiers";
import { typeDisplayName } from "../../checker/types";
import { resolveRuntimeDir, isBuiltinStubHeader } from "../../utils/path";

let _collecting = false;
let _demands: Symbol[] = [];

export function collectNativeDemands(on: boolean): void {
	_collecting = on;
}

export function takeNativeDemands(): Symbol[] {
	const taken = _demands;
	_demands = [];
	return taken;
}

function isCIdentifier(name: string): boolean {
	if (name == "") return false;
	for (let i = 0; i < name.length; i += 1) {
		const c = name.charCodeAt(i);
		const letter = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95;
		if (!letter && !(i > 0 && c >= 48 && c <= 57)) return false;
	}
	return true;
}

function bridgedType(t: Type | null): Type | null {
	let cur = t;
	while (cur != null && (cur.kind == TypeKind.Alias || cur.kind == TypeKind.Distinct || cur.kind == TypeKind.Sink || cur.kind == TypeKind.Lent)) cur = cur.typeReturn;
	return cur;
}

export function bridgeClassOf(declared: Type | null, result: boolean): string {
	const t = bridgedType(declared);
	if (t == null) return "";
	return match (t.kind) {
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64
			| TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64
			| TypeKind.Char | TypeKind.Enum | TypeKind.Boolean => "i",
		TypeKind.Number | TypeKind.Float32 | TypeKind.Float64 => "f",
		TypeKind.CString => result ? "" : "s",
		TypeKind.Void => result ? "v" : "",
		_ => "",
	};
}

export function nativeSignature(sym: Symbol): string {
	const fn = sym.symbolType;
	if (fn == null || fn.kind != TypeKind.Function) return "";
	let sig = "";
	for (const p of fn.typeChildren) {
		const c = bridgeClassOf(p, false);
		if (c == "") return "";
		sig = sig + c;
	}
	const r = bridgeClassOf(fn.typeReturn, true);
	return r == "" ? "" : `${sig}:${r}`;
}

function signatureRefusal(sym: Symbol): string {
	const fn = sym.symbolType;
	if (fn == null || fn.kind != TypeKind.Function) return `'${sym.nativeName}' is not a function`;
	for (let i = 0; i < fn.typeChildren.length; i += 1) {
		if (bridgeClassOf(fn.typeChildren[i], false) == "") return `its native bridge does not carry parameter ${i + 1} of type ${typeDisplayName(fn.typeChildren[i])} yet; it carries numbers and booleans, and C strings as arguments`;
	}
	return `its native bridge does not carry a result of type ${typeDisplayName(fn.typeReturn)} yet; it carries numbers and booleans, and C strings as arguments`;
}

export function isProgramModule(modulePath: string): boolean {
	const root = resolveRuntimeDir();
	return stdModuleName(modulePath) == "" && !modulePath.startsWith(`${root}/runtime/`) && !isBuiltinStubHeader(modulePath);
}

export function isNativeExtern(sym: Symbol): boolean {
	return isProgramModule(sym.modulePath) && isCIdentifier(sym.nativeName);
}

// "" when the run builds a bridge for sym, the reason it cannot when sym is the program's own C, null otherwise.
export function demandNativeBridge(sym: Symbol): string | null {
	if (!_collecting || !isNativeExtern(sym)) return null;
	if (nativeSignature(sym) == "") return signatureRefusal(sym);
	for (const d of _demands) if (d.nativeName == sym.nativeName) return "";
	_demands.push(sym);
	return "";
}

function argExpr(c: string, i: int32): string {
	if (c == "f") return `msRaiserBridgeF64(a[${i}])`;
	if (c == "s") return `(char*)(intptr_t)a[${i}]`;
	return `a[${i}]`;
}

export function bridgeFunctionName(index: int32): string {
	return `msRaiserBridge${index}`;
}

function bridgeDefinition(sym: Symbol, index: int32): string {
	const sig = nativeSignature(sym);
	const colon = sig.indexOf(":");
	const args: string[] = [];
	for (let i: int32 = 0; i < colon; i += 1) args.push(argExpr(sig.charAt(i), i));
	const call = `${sym.nativeName}(${args.join(", ")})`;
	const r = sig.charAt(colon + 1);
	const body = r == "v" ? `${call}; (void)r;`
		: r == "f" ? `*r = msRaiserBridgeBits((double)${call});`
		: `*r = (int64_t)${call};`;
	return `static void ${bridgeFunctionName(index)}(const int64_t* a, int64_t* r) { (void)a; ${body} }`;
}

export function bridgeSource(demands: Symbol[], includes: string[]): string {
	const lines: string[] = ["#include <stdint.h>"];
	for (const header of includes) lines.push(`#include "${header}"`);
	lines.push(`#include "runtime/raiser/bridge.h"`);
	for (let i: int32 = 0; i < demands.length; i += 1) lines.push(bridgeDefinition(demands[i], i));
	lines.push("MS_RAISER_BRIDGE_EXPORT const MsRaiserBridge msRaiserBridges[] = {");
	for (let i: int32 = 0; i < demands.length; i += 1) lines.push(`\t{"${demands[i].nativeName}", "${nativeSignature(demands[i])}", ${bridgeFunctionName(i)}},`);
	lines.push("\t{0, 0, 0},");
	lines.push("};");
	return lines.join("\n") + "\n";
}
