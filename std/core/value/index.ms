// Value equality and value dump: one routine per type, folded from the type's fields.
// The checker routes `==` / `!=` and string conversion of a value type to these by symbol.

import { equalsFold, dumpFold, debugLabel } from "std/core/value/fold";

// The generic entry the checker calls for a struct, tuple or fixed array operand.
@compilerFunc
export function valueEquals<T>(a: T, b: T): boolean {
	equalsFold(a, b);
	return true;
}

// `T | null` over a value payload: equal when both are null or both hold equal payloads.
@compilerFunc
export function nullableEquals<T>(a: T | null, b: T | null): boolean {
	if (a == null) return b == null;
	if (b == null) return false;
	return a == b;
}

@compilerFunc
export function resultEquals<T, E>(a: Result<T, E>, b: Result<T, E>): boolean {
	if (a.ok) {
		if (!b.ok) return false;
		return a.value == b.value;
	}
	if (b.ok) return false;
	return a.error == b.error;
}

@compilerFunc
export function vecEquals<T>(a: Vec<T>, b: Vec<T>): boolean {
	if (a.length != b.length) return false;
	for (let i = 0; i < a.length; i += 1) {
		if (a[i] != b[i]) return false;
	}
	return true;
}

function nullText(color: boolean): string {
	return color ? "\x1b[2mnull\x1b[0m" : "null";
}

function openObject(color: boolean): string {
	return color ? "{ " : "{";
}

function closeObject(color: boolean): string {
	return color ? " }" : "}";
}

function separator(color: boolean): string {
	return color ? ", " : ",";
}

function key(name: string, color: boolean): string {
	return color ? name + ": " : stringify(jsonString(name), false) + ":";
}

function textLeaf(s: string, color: boolean): string {
	return stringify(jsonString(s), color);
}

function boolLeaf(v: boolean, color: boolean): string {
	return stringify(jsonBool(v), color);
}

function numberLeaf(v: float64, color: boolean): string {
	return stringify(jsonNumber(v), color);
}

function integerLeaf(v: int64, color: boolean): string {
	return stringify(jsonInt(v), color);
}

function enumLeaf<T>(v: T, color: boolean): string {
	return stringify(jsonInt(v as int32), color);
}

when (!bare && !solana) {
	function bigintLeaf(v: bigint): string {
		return `${v}`;
	}
}

@compilerFunc
export function valueDump<T>(x: T, color: boolean): string {
	let out = "";
	dumpFold(x, color);
	return out;
}

function arrayDump<T>(xs: T[], color: boolean): string {
	let out = "[";
	for (let i = 0; i < xs.length; i = i + 1) {
		if (i > 0) out = out + separator(color);
		out = out + valueDump(xs[i], color);
	}
	return out + "]";
}

function nullableDump<T>(x: T | null, color: boolean): string {
	if (x == null) return nullText(color);
	return valueDump(x, color);
}

function resultDump<T, E>(r: Result<T, E>, color: boolean): string {
	if (r.ok) return openObject(color) + key("ok", color) + boolLeaf(true, color) + separator(color) + key("value", color) + valueDump(r.value, color) + closeObject(color);
	return openObject(color) + key("ok", color) + boolLeaf(false, color) + separator(color) + key("error", color) + valueDump(r.error, color) + closeObject(color);
}

@compilerFunc
@builtin("UnionText")
extern function unionMemberText<T, H>(x: T, holder: H, ...texts: string[]): string;

@compilerFunc
@builtin("UnionDebug")
extern function unionMemberDebug<T, H>(x: T, holder: H, ...texts: string[]): string;

@compilerFunc
export function valueDebug<T>(x: T): string {
	return debugLabel(x) + valueDump(x, true);
}
