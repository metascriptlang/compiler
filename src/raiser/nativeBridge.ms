import { RaiserVM, registerInPlaceHostFn, hostArgInt, hostArgFloat, hostArgString, hostReturnInt, hostReturnFloat } from "./vm";

@include("runtime/hcr.h")
@include("runtime/raiser/bridge.h")
extern function msHcrImageOpen(path: cstring): Ptr<void>;
extern function msHcrImageSymbol(handle: Ptr<void>, name: cstring): Ptr<void>;
extern function msHcrImageFailure(): cstring;
extern function msHcrImageIsNull(value: Ptr<void>): int32;
extern function msRaiserBridgeCount(table: Ptr<void>): int64;
extern function msRaiserBridgeName(table: Ptr<void>, i: int64): cstring;
extern function msRaiserBridgeSig(table: Ptr<void>, i: int64): cstring;
extern function msRaiserBridgeFnAt(table: Ptr<void>, i: int64): Ptr<void>;
extern function msRaiserBridgeCall(fn: Ptr<void>, args: Ptr<int64>, result: Ptr<int64>): void;
extern function msRaiserBridgeWords(n: int64): Ptr<int64>;
extern function msRaiserBridgeSetText(args: Ptr<int64>, i: int64, text: cstring): void;
extern function msRaiserBridgeFreeText(args: Ptr<int64>, i: int64): void;
extern function msRaiserBridgeF64(bits: int64): float64;
extern function msRaiserBridgeBits(d: float64): int64;

export const BRIDGE_TABLE_SYMBOL = "msRaiserBridges";

const CLASS_INT: int32 = 105;
const CLASS_FLOAT: int32 = 102;
const CLASS_TEXT: int32 = 115;
const CLASS_VOID: int32 = 118;

function classesOf(sig: string): int32[] {
	const classes: int32[] = [];
	for (let i = 0; i < sig.length; i += 1) classes.push(sig.charCodeAt(i) as int32);
	return classes;
}

function hasText(classes: int32[]): boolean {
	for (const c of classes) if (c == CLASS_TEXT) return true;
	return false;
}

function signatureRefusal(name: string, sig: string): string | null {
	const colon = sig.indexOf(":");
	if (colon < 0 || colon != sig.length - 2) return `the native bridge of '${name}' has signature '${sig}', which names no result class`;
	for (let i = 0; i < sig.length; i += 1) {
		if (i == colon) continue;
		const c = sig.charCodeAt(i) as int32;
		const result = i == sig.length - 1;
		if (c == CLASS_INT || c == CLASS_FLOAT || (result ? c == CLASS_VOID : c == CLASS_TEXT)) continue;
		return `the native bridge of '${name}' has signature '${sig}', whose class '${sig.charAt(i)}' the Raiser does not read`;
	}
	return null;
}

function registerBridge(name: string, sig: string, fn: Ptr<void>): void {
	const params = classesOf(sig.slice(0, sig.length - 2));
	const result = sig.charCodeAt(sig.length - 1) as int32;
	const n = params.length;
	const args = msRaiserBridgeWords(n as int64);
	const out = msRaiserBridgeWords(1);
	const texts = hasText(params);
	registerInPlaceHostFn(name, (vm: RaiserVM): void => {
		for (let i: int32 = 0; i < n; i += 1) {
			const c = params[i];
			if (c == CLASS_INT) args[i] = hostArgInt(vm, i);
			else if (c == CLASS_FLOAT) args[i] = msRaiserBridgeBits(hostArgFloat(vm, i));
			else {
				const text = hostArgString(vm, i);
				msRaiserBridgeSetText(args, i as int64, text as cstring);
			}
		}
		msRaiserBridgeCall(fn, args, out);
		if (texts) for (let i: int32 = 0; i < n; i += 1) if (params[i] == CLASS_TEXT) msRaiserBridgeFreeText(args, i as int64);
		if (result == CLASS_INT) hostReturnInt(vm, out[0]);
		else if (result == CLASS_FLOAT) hostReturnFloat(vm, msRaiserBridgeF64(out[0]));
	});
}

export function registerBridgeTable(table: Ptr<void>): string | null {
	const count = msRaiserBridgeCount(table);
	for (let i: int64 = 0; i < count; i += 1) {
		const refusal = signatureRefusal(msRaiserBridgeName(table, i) as string, msRaiserBridgeSig(table, i) as string);
		if (refusal != null) return refusal;
	}
	for (let i: int64 = 0; i < count; i += 1) registerBridge(msRaiserBridgeName(table, i) as string, msRaiserBridgeSig(table, i) as string, msRaiserBridgeFnAt(table, i));
	return null;
}

export function loadBridgeLibrary(path: string): string | null {
	const handle = msHcrImageOpen(path as cstring);
	if (msHcrImageIsNull(handle) != 0) return `cannot load the native bridges of the program from ${path}: ${msHcrImageFailure() as string}`;
	const table = msHcrImageSymbol(handle, BRIDGE_TABLE_SYMBOL as cstring);
	if (msHcrImageIsNull(table) != 0) return `${path} exports no '${BRIDGE_TABLE_SYMBOL}' table`;
	return registerBridgeTable(table);
}
