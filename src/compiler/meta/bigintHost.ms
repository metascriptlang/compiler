// Host bridges for the bigint runtime entries (runtime/bigint/bigint.h); src/raiser/bigint.ms does the work.

import { RaiserValue, raiserNil, raiserInt } from "../../raiser/value";
import { HostCapability, registerHostFn, raiseFromHost } from "../../raiser/hostRegistry";
import { unboxString, unboxFloat, unboxBigInt, boxString, boxFloat, boxBool, boxBigInt } from "../../raiser/marshal";
import {
	bigFromLit, bigParses, bigParse, bigToString, bigToDebug, bigFromInt64, bigFromUint64, bigFromFloat64,
	bigToInt64, bigToSigned, bigToFloat32, bigToFloat64, bigAsIntN, bigAsUintN, bigAdd, bigSub, bigMul,
	bigDiv, bigMod, bigPow, bigAnd, bigOr, bigXor, bigShl, bigShr, bigNeg, bigNot, bigCmp, bigIsZero,
	bigCompareFloat64, float64CompareBig,
} from "../../raiser/bigint";

function guarded(run: () => RaiserValue): RaiserValue {
	try {
		return run();
	} catch (e) {
		raiseFromHost(e.message, true);
		return raiserNil();
	}
}

function binary(op: (a: string, b: string) => string): (args: RaiserValue[]) => RaiserValue {
	return (args: RaiserValue[]): RaiserValue => guarded((): RaiserValue => boxBigInt(op(unboxBigInt(args[0]), unboxBigInt(args[1]))));
}

function unary(op: (a: string) => string): (args: RaiserValue[]) => RaiserValue {
	return (args: RaiserValue[]): RaiserValue => guarded((): RaiserValue => boxBigInt(op(unboxBigInt(args[0]))));
}

function parsed(op: (text: string) => string): (args: RaiserValue[]) => RaiserValue {
	return (args: RaiserValue[]): RaiserValue => guarded((): RaiserValue => boxBigInt(op(unboxString(args[0]))));
}

export function registerBigIntKernels(): void {
	registerHostFn("msBigIntAdd", binary(bigAdd), HostCapability.Pure);
	registerHostFn("msBigIntSub", binary(bigSub), HostCapability.Pure);
	registerHostFn("msBigIntMul", binary(bigMul), HostCapability.Pure);
	registerHostFn("msBigIntDiv", binary(bigDiv), HostCapability.Pure);
	registerHostFn("msBigIntMod", binary(bigMod), HostCapability.Pure);
	registerHostFn("msBigIntPow", binary(bigPow), HostCapability.Pure);
	registerHostFn("msBigIntAnd", binary(bigAnd), HostCapability.Pure);
	registerHostFn("msBigIntOr", binary(bigOr), HostCapability.Pure);
	registerHostFn("msBigIntXor", binary(bigXor), HostCapability.Pure);
	registerHostFn("msBigIntShl", binary(bigShl), HostCapability.Pure);
	registerHostFn("msBigIntShr", binary(bigShr), HostCapability.Pure);
	registerHostFn("msBigIntNeg", unary(bigNeg), HostCapability.Pure);
	registerHostFn("msBigIntNot", unary(bigNot), HostCapability.Pure);
	registerHostFn("msBigIntFromLit", parsed(bigFromLit), HostCapability.Pure);
	registerHostFn("msBigIntParse", parsed(bigParse), HostCapability.Pure);
	registerHostFn("msBigIntToDebugString", (args: RaiserValue[]): RaiserValue => boxString(bigToDebug(unboxBigInt(args[0]))), HostCapability.Pure);
	registerHostFn("msBigIntParses", (args: RaiserValue[]): RaiserValue => boxBool(bigParses(unboxString(args[0]))), HostCapability.Pure);
	registerHostFn("msBigIntIsZero", (args: RaiserValue[]): RaiserValue => boxBool(bigIsZero(unboxBigInt(args[0]))), HostCapability.Pure);
	registerHostFn("msBigIntCmp", (args: RaiserValue[]): RaiserValue => raiserInt(bigCmp(unboxBigInt(args[0]), unboxBigInt(args[1]))), HostCapability.Pure);
	registerHostFn("msBigIntToString", (args: RaiserValue[]): RaiserValue => guarded((): RaiserValue => boxString(bigToString(unboxBigInt(args[0]), args[1].intVal as int32))), HostCapability.Pure);
	registerHostFn("msBigIntFromInt64", (args: RaiserValue[]): RaiserValue => boxBigInt(bigFromInt64(args[0].intVal)), HostCapability.Pure);
	registerHostFn("msBigIntFromUint64", (args: RaiserValue[]): RaiserValue => boxBigInt(bigFromUint64(args[0].intVal)), HostCapability.Pure);
	registerHostFn("msBigIntFromFloat64", (args: RaiserValue[]): RaiserValue => guarded((): RaiserValue => boxBigInt(bigFromFloat64(unboxFloat(args[0])))), HostCapability.Pure);
	registerHostFn("msBigIntToInt64", (args: RaiserValue[]): RaiserValue => raiserInt(bigToInt64(unboxBigInt(args[0]))), HostCapability.Pure);
	registerHostFn("msBigIntToSigned", (args: RaiserValue[]): RaiserValue => guarded((): RaiserValue => raiserInt(bigToSigned(unboxBigInt(args[0]), args[1].intVal as int32))), HostCapability.Pure);
	registerHostFn("msBigIntToFloat32", (args: RaiserValue[]): RaiserValue => boxFloat(bigToFloat32(unboxBigInt(args[0]))), HostCapability.Pure);
	registerHostFn("msBigIntToFloat64", (args: RaiserValue[]): RaiserValue => boxFloat(bigToFloat64(unboxBigInt(args[0]))), HostCapability.Pure);
	registerHostFn("msBigIntAsIntN", (args: RaiserValue[]): RaiserValue => guarded((): RaiserValue => boxBigInt(bigAsIntN(args[0].intVal, unboxBigInt(args[1])))), HostCapability.Pure);
	registerHostFn("msBigIntAsUintN", (args: RaiserValue[]): RaiserValue => guarded((): RaiserValue => boxBigInt(bigAsUintN(args[0].intVal, unboxBigInt(args[1])))), HostCapability.Pure);
	registerHostFn("msBigIntCompareFloat64", (args: RaiserValue[]): RaiserValue => raiserInt(bigCompareFloat64(unboxBigInt(args[0]), unboxFloat(args[1]), args[2].intVal as int32)), HostCapability.Pure);
	registerHostFn("msFloat64CompareBigInt", (args: RaiserValue[]): RaiserValue => raiserInt(float64CompareBig(unboxFloat(args[0]), unboxBigInt(args[1]), args[2].intVal as int32)), HostCapability.Pure);
}
