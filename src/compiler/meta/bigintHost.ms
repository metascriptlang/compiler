// Host bridges for the bigint runtime entries (runtime/bigint/bigint.h); src/raiser/bigint.ms does the work.

import { RaiserValue, raiserInt } from "../../raiser/value";
import { HostCapability, raiseFromHost } from "../../raiser/hostRegistry";
import { RaiserVM, registerInPlaceHostFn, hostArg, hostArgFloat, hostArgInt, hostArgString, hostReturn, hostReturnInt, hostReturnFloat, hostReturnString, hostReturnBool } from "../../raiser/vm";
import { unboxBigInt, boxString, boxBigInt } from "../../raiser/marshal";
import {
	bigFromLit, bigParses, bigParse, bigToString, bigToDebug, bigFromInt64, bigFromUint64, bigFromFloat64,
	bigToInt64, bigToSigned, bigToFloat32, bigToFloat64, bigAsIntN, bigAsUintN, bigAdd, bigSub, bigMul,
	bigDiv, bigMod, bigPow, bigAnd, bigOr, bigXor, bigShl, bigShr, bigNeg, bigNot, bigCmp, bigIsZero,
	bigCompareFloat64, float64CompareBig,
} from "../../raiser/bigint";

function guarded(vm: RaiserVM, run: () => RaiserValue): void {
	try {
		hostReturn(vm, run());
	} catch (e) {
		raiseFromHost(e.message, true);
	}
}

function bigArg(vm: RaiserVM, i: int32): string {
	return unboxBigInt(hostArg(vm, i));
}

function binary(op: (a: string, b: string) => string): (vm: RaiserVM) => void {
	return (vm: RaiserVM): void => guarded(vm, (): RaiserValue => boxBigInt(op(bigArg(vm, 0), bigArg(vm, 1))));
}

function unary(op: (a: string) => string): (vm: RaiserVM) => void {
	return (vm: RaiserVM): void => guarded(vm, (): RaiserValue => boxBigInt(op(bigArg(vm, 0))));
}

function parsed(op: (text: string) => string): (vm: RaiserVM) => void {
	return (vm: RaiserVM): void => guarded(vm, (): RaiserValue => boxBigInt(op(hostArgString(vm, 0))));
}

export function registerBigIntKernels(): void {
	registerInPlaceHostFn("msBigIntAdd", binary(bigAdd), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntSub", binary(bigSub), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntMul", binary(bigMul), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntDiv", binary(bigDiv), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntMod", binary(bigMod), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntPow", binary(bigPow), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntAnd", binary(bigAnd), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntOr", binary(bigOr), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntXor", binary(bigXor), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntShl", binary(bigShl), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntShr", binary(bigShr), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntNeg", unary(bigNeg), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntNot", unary(bigNot), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntFromLit", parsed(bigFromLit), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntParse", parsed(bigParse), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntToDebugString", (vm: RaiserVM): void => hostReturnString(vm, bigToDebug(bigArg(vm, 0))), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntParses", (vm: RaiserVM): void => hostReturnBool(vm, bigParses(hostArgString(vm, 0))), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntIsZero", (vm: RaiserVM): void => hostReturnBool(vm, bigIsZero(bigArg(vm, 0))), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntCmp", (vm: RaiserVM): void => hostReturnInt(vm, bigCmp(bigArg(vm, 0), bigArg(vm, 1))), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntToString", (vm: RaiserVM): void => guarded(vm, (): RaiserValue => boxString(bigToString(bigArg(vm, 0), hostArgInt(vm, 1) as int32))), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntFromInt64", (vm: RaiserVM): void => hostReturn(vm, boxBigInt(bigFromInt64(hostArgInt(vm, 0)))), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntFromUint64", (vm: RaiserVM): void => hostReturn(vm, boxBigInt(bigFromUint64(hostArgInt(vm, 0)))), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntFromFloat64", (vm: RaiserVM): void => guarded(vm, (): RaiserValue => boxBigInt(bigFromFloat64(hostArgFloat(vm, 0)))), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntToInt64", (vm: RaiserVM): void => hostReturnInt(vm, bigToInt64(bigArg(vm, 0))), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntToSigned", (vm: RaiserVM): void => guarded(vm, (): RaiserValue => raiserInt(bigToSigned(bigArg(vm, 0), hostArgInt(vm, 1) as int32))), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntToFloat32", (vm: RaiserVM): void => hostReturnFloat(vm, bigToFloat32(bigArg(vm, 0))), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntToFloat64", (vm: RaiserVM): void => hostReturnFloat(vm, bigToFloat64(bigArg(vm, 0))), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntAsIntN", (vm: RaiserVM): void => guarded(vm, (): RaiserValue => boxBigInt(bigAsIntN(hostArgInt(vm, 0), bigArg(vm, 1)))), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntAsUintN", (vm: RaiserVM): void => guarded(vm, (): RaiserValue => boxBigInt(bigAsUintN(hostArgInt(vm, 0), bigArg(vm, 1)))), HostCapability.Pure);
	registerInPlaceHostFn("msBigIntCompareFloat64", (vm: RaiserVM): void => hostReturnInt(vm, bigCompareFloat64(bigArg(vm, 0), hostArgFloat(vm, 1), hostArgInt(vm, 2) as int32)), HostCapability.Pure);
	registerInPlaceHostFn("msFloat64CompareBigInt", (vm: RaiserVM): void => hostReturnInt(vm, float64CompareBig(hostArgFloat(vm, 0), bigArg(vm, 1), hostArgInt(vm, 2) as int32)), HostCapability.Pure);
}
