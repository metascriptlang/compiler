import { Node, NodeKind, CallExprData, Symbol } from "../../ast/node";
import { SymbolFlag, hasFlag } from "../../checker/symbol";

export const ROW_INCREF: int32 = 1;
export const ROW_DECREF: int32 = 2;
export const ROW_DECREF_CYCLIC: int32 = 3;
export const ROW_CLEAR: int32 = 4;
export const ROW_SINK: int32 = 5;
export const ROW_SHARE: int32 = 7;
export const ROW_HELD: int32 = 8;
export const ROW_KEPT: int32 = 9;
export const ROW_COPY_VALUE: int32 = 10;

const rows = new HashMap<string, int32>();

function define(row: int32, names: string[]): void {
	for (const name of names) rows.set(name, row);
}

define(ROW_INCREF, ["msIncref", "msIncrefCyclic", "msAtomicIncref", "msStringIncref", "msClosureCopy"]);
define(ROW_DECREF, [
	"msDecref", "msAtomicDecref", "msStringDecref", "msClosureDestroy", "msStructCellDestroy",
	"msArrayDestroy", "msArrayStringDestroy", "msArrayUint8Destroy", "msArrayRefDestroy", "msArrayAcyclicRefDestroy", "msArrayAtomicRefDestroy",
	"msArrayClosureDestroy", "msClosureArrayDestroy", "msNumberArrayDestroy", "msStringArrayDestroy", "msRefArrayDestroy", "msAcyclicRefArrayDestroy", "msAtomicRefArrayDestroy",
]);
define(ROW_DECREF_CYCLIC, ["msDecrefCyclic"]);
define(ROW_CLEAR, [
	"msPtrWasMoved", "msPlainWasMoved", "msClosureWasMoved", "msStringWasMoved", "msStructCellWasMoved", "msArrayWasMoved", "msArrayNumberWasMoved", "msArrayUint8WasMoved",
	"msArrayStringWasMoved", "msArrayRefWasMoved", "msArrayClosureWasMoved",
]);
define(ROW_SINK, ["msStructCellSink", "msArrayClosureSink", "msClosureSink", "msStringSink", "msArrayNumberSink", "msArrayUint8Sink", "msArrayStringSink", "msArrayRefSink", "msArrayAcyclicRefSink"]);
define(ROW_SHARE, ["msStringCopy"]);
define(ROW_HELD, ["msHeldCount"]);
define(ROW_KEPT, ["msDestroyLeftNoRef"]);
define(ROW_COPY_VALUE, [
	"msArrayCopy", "msArrayUint8Copy", "msArrayStringCopy", "msArrayRefCopy", "msArrayAcyclicRefCopy", "msArrayAtomicRefCopy",
	"msArrayClosureCopy", "msStructCellCopy",
]);

export function ownershipName(sym: Symbol | null): string {
	if (sym == null || !hasFlag(sym, SymbolFlag.CompilerProc)) return "";
	return sym.nativeName != "" ? sym.nativeName : sym.name;
}

export function ownershipRow(sym: Symbol | null): int32 {
	const name = ownershipName(sym);
	return name != "" && rows.has(name) ? rows.get(name)! : 0;
}

export function refuseOwnershipCall(call: Node): void {
	if (call.kind != NodeKind.CallExpr) return;
	const sym = (call.data as CallExprData).callee.resolvedSym;
	if (ownershipRow(sym) != 0) throw new Error(`internal: Raiser has no lowering for ${ownershipName(sym)} outside statement position`);
}

export function refuseUnknownRuntimeProc(sym: Symbol | null): void {
	if (sym == null || sym.declNode != null || !hasFlag(sym, SymbolFlag.CompilerProc)) return;
	throw new Error(`internal: Raiser has no lowering for ${ownershipName(sym)}`);
}
