@include("runtime/core/system.h");
@compile("runtime/core/system.c");
@compile("runtime/drc.c");

export class console {
	/**
	 * The **`console.log()`** static method outputs a message to the console.
	 *
	 * [MDN Reference](https://developer.mozilla.org/docs/Web/API/console/log_static)
	 */
	@builtin("Echo")
	static extern log(...values: unknown[]): void from "msPrintln";

	@builtin("Echo")
	static extern warn(...values: unknown[]): void from "msWarnln";

	@builtin("Echo")
	static extern error(...values: unknown[]): void from "msEprintln";
}

export class process {
	/** Terminate the process with the given status code. */
	static extern exit(code: int32 = 0): never from "msExit";
}

/**
 * Schedules `fn` to run after `ms` milliseconds, returning a handle for
 * `clearTimeout`. The callback runs on the event loop, so a program that never
 * enters one (a purely synchronous `main`) exits before its timers fire.
 */
export extern function setTimeout(fn: () => void, ms: number): number from "msSetTimeout";
/** Cancels a pending `setTimeout`. Unknown handles are ignored. */
export extern function clearTimeout(id: number): void from "msClearTimeout";
/** Schedules `fn` to run every `ms` milliseconds until `clearInterval`. */
export extern function setInterval(fn: () => void, ms: number): number from "msSetInterval";
/** Cancels a repeating `setInterval`. Unknown handles are ignored. */
export extern function clearInterval(id: number): void from "msClearInterval";

@builtin("Result")
export class Result<T, E> {
	ok: boolean;
	value: T;
	error: E;

	/** Creates a successful Result wrapping the given value. */
	@builtin("ResultOk")
	static extern ok(val: T): Result<T, E>;
	/** Creates an error Result wrapping the given error. */
	@builtin("ResultErr")
	static extern err(e: E): Result<T, E>;
}

export class Error {
	message: string;

	constructor(message: string) {
		this.message = message;
	}
}

@builtin("compilerFunc")
export extern function compilerFunc(): void;

@builtin("throws")
export extern function throws(): void;

@builtin("delegate")
export extern function delegate(): void;

@compilerFunc @throws
extern function msAssertFail(msg: cstring, file: cstring, line: int32): void from "msAssertFail";

@compilerFunc @throws
extern function msAwaitSlotResult(slot: Ptr<void>): Ptr<void> from "msAwaitSlotResult";

@compilerFunc @throws
extern function msAwaitGroupCheckFailed(group: Ptr<void>): void from "msAwaitGroupCheckFailed";

@compilerFunc @throws
extern function msFutureCheckErr(fut: Ptr<void>): boolean from "msFutureCheckErr";

@compilerFunc @throws
extern function msFutureRead(fut: Ptr<void>): Ptr<void> from "msFutureRead";

@compilerFunc @throws
extern function msFutureReadDouble(fut: Ptr<void>): number from "msFutureReadDouble";

@compilerFunc @throws
extern function msFutureReadInt32(fut: Ptr<void>): int32 from "msFutureReadInt32";

@compilerFunc @throws
extern function msFutureReadBool(fut: Ptr<void>): boolean from "msFutureReadBool";

@compilerFunc @throws
extern function msFutureReadString(fut: Ptr<void>): string from "msFutureReadString";

@throws
extern function msAbortThrow(): void from "msAbortThrow";

@compilerFunc
extern function msFutureCompleteT(fut: Ptr<void>, sink value: Ptr<void>): void from "msFutureCompleteT";

@compilerFunc
extern function msGenericArrayPush(arr: Ptr<void>, sink value: Ptr<void>): void from "msGenericArrayPush";

@compilerFunc @builtin("SpawnInto")
extern function msSpawnInto(sink fut: Ptr<void>, fn: Ptr<void>): Ptr<void>;

@compilerFunc @builtin("FutureCreateInline")
extern function msFutureCreateInline(): Ptr<void>;

@compilerFunc @builtin("WaitForStruct")
extern function msWaitForStruct(fut: Ptr<void>): Ptr<void>;

@compilerFunc @builtin("FutureThenBoxed")
extern function msFutureThenBoxed(input: Ptr<void>, onFulfilled: Ptr<void>): Ptr<void>;

@compilerFunc @builtin("BoxStruct")
extern function msBoxStruct(val: Ptr<void>): Ptr<void>;

@compilerFunc @builtin("SinkBoxStruct")
extern function msSinkBoxStruct(val: Ptr<void>): Ptr<void>;

@compilerFunc @builtin("UnboxStruct")
extern function msUnboxStruct(box: Ptr<void>): Ptr<void>;

@compilerFunc @builtin("BoxRefArray")
extern function msBoxRefArray(arr: Ptr<void>): Ptr<void>;

@compilerFunc @builtin("BoxArc")
extern function msBoxArc(val: Ptr<void>): Ptr<void>;

@compilerFunc @builtin("BoxLocked")
extern function msBoxLocked(val: Ptr<void>): Ptr<void>;

@compilerFunc @builtin("StringConcatArr")
extern function msStringConcatArr(count: int32, ...parts: string[]): string;

@compilerFunc @builtin("StringAppendArr")
extern function msStringAppendArr(dest: Ptr<void>, count: int32, ...parts: string[]): void;

@compilerFunc @builtin("StringArrayFromArr")
extern function msStringArrayFromArr(count: int32, ...parts: string[]): string[];

@compilerFunc @builtin("NumberArrayFrom")
extern function msNumberArrayFrom(count: int32, ...values: float64[]): float64[];

@compilerFunc
extern function msMsgCompleteDouble(fut: Ptr<void>, sink val: float64): void from "msMsgCompleteDouble";

@compilerFunc
extern function msMsgCompleteInt32(fut: Ptr<void>, sink val: int32): void from "msMsgCompleteInt32";

@compilerFunc
extern function msMsgCompleteInt64(fut: Ptr<void>, sink val: int64): void from "msMsgCompleteInt64";

@compilerFunc
extern function msMsgCompleteBool(fut: Ptr<void>, sink val: boolean): void from "msMsgCompleteBool";

@compilerFunc
extern function msMsgCompletePtr(fut: Ptr<void>, sink val: Ptr<void>): void from "msMsgCompletePtr";

@compilerFunc
extern function msMsgCompleteString(fut: Ptr<void>, sink val: string): void from "msMsgCompleteString";

extern function codePointString(cp: int64): string from "msStringFromCodePoint";

@compilerFunc
export function msCharToString(c: char): string {
	const b = c as uint8;
	return codePointString(b < 0x80 ? b as int64 : 0xFFFD);
}

when (raiser) {
	@compilerFunc
	extern function msUnionRead(u: Ptr<void>, slots: int32[], head: string, labels: string[]): Ptr<void>;

	@compilerFunc
	extern function msUnionReadMaybe(u: Ptr<void>, slots: int32[], head: string, labels: string[]): Ptr<void>;

	@compilerFunc
	extern function msUnionWrapMaybe(v: Ptr<void>, tag: int32): Ptr<void>;
}

export class AbortSignal {
	aborted: boolean;
	reason: string;

	constructor() {
		this.aborted = false;
		this.reason = "";
	}

	throwIfAborted(): void {
		if (this.aborted) {
			msAbortThrow();
		}
	}

	static abort(reason: string): AbortSignal {
		const s = new AbortSignal();
		s.aborted = true;
		s.reason = reason;
		return s;
	}
}

export class AbortController {
	signal: AbortSignal;

	constructor() {
		this.signal = new AbortSignal();
	}

	abort(reason: string): void {
		if (!this.signal.aborted) {
			this.signal.aborted = true;
			this.signal.reason = reason;
		}
	}
}

when (mscDeclaresRuntime) {
	// ===== Runtime routines the compiler synthesizes calls to =====
	// A macro that dispatches on its argument count is declared at its widest arity.

	@compilerFunc
	extern function msIncref(p: Ptr<void>): void;

	@compilerFunc
	extern function msDecref(p: Ptr<void>): void;

	@compilerFunc
	extern function msIncRef(p: Ptr<void>): void;

	@compilerFunc
	extern function msIncrefCyclic(p: Ptr<void>): void;

	@compilerFunc
	extern function msDecrefCyclic(p: Ptr<void>): void;

	@compilerFunc
	extern function msAtomicIncref(p: Ptr<void>): void;

	@compilerFunc
	extern function msAtomicDecref(p: Ptr<void>): void;

	@compilerFunc
	extern function msPtrWasMoved(p: Ptr<void>): void;

	@compilerFunc
	extern function msPlainWasMoved(x: Ptr<void>): void;

	@compilerFunc
	extern function msRefCopyCyclic(d: Ptr<void>, s: Ptr<void>): void;

	@compilerFunc
	extern function msOrcBeginTeardown(): void;

	@compilerFunc
	extern function msOrcEndTeardown(): void;

	@compilerFunc
	extern function msOrcTraceRef(child: Ptr<void>, env: Ptr<void>): void;

	@compilerFunc
	extern function msStringDecref(s: string): void;

	@compilerFunc
	extern function msStringIncref(s: string): void;

	@compilerFunc
	extern function msStringWasMoved(s: string): void;

	@compilerFunc
	extern function msStringSink(d: string, v: string): void;

	@compilerFunc
	extern function msStringCopy(dest: Ptr<void>, src: string): void;

	@compilerFunc
	extern function msStringAppend(dest: Ptr<void>, src: string): void;

	@compilerFunc
	extern function msStringAppendChar(dest: Ptr<void>, ch: char): void;

	@compilerFunc
	extern function msStringSetChar(s: Ptr<void>, idx: int64, ch: string): void;

	@compilerFunc
	extern function msStringConcat(a: string, b: string): string;

	@compilerFunc
	extern function msStringEquals(a: string, b: string): boolean;

	@compilerFunc
	extern function msStringHash(s: string): int32;

	@compilerFunc
	extern function msStringLength(s: string): int64;

	@compilerFunc
	extern function msStringByteLength(s: string): int64;

	@compilerFunc
	extern function msStringUnicodeLength(s: string): int64;

	@compilerFunc
	extern function msStringByteAt(s: string, idx: int64): int64;

	@compilerFunc
	extern function msStringToCString(s: string): cstring;

	@compilerFunc
	extern function msBoolToString(value: int32): string;

	@compilerFunc
	extern function msIntToString(value: int64): string;

	@compilerFunc
	extern function msIntToStringRadix(value: int64, radix: float64): string;

	@compilerFunc
	extern function msUint64ToString(value: uint64): string;

	@compilerFunc
	extern function msUint64ToStringRadix(value: uint64, radix: float64): string;

	@compilerFunc
	extern function msNumberToString(value: float64): string;

	@compilerFunc
	extern function msNumberToStringRadix(value: float64, radix: float64): string;

	@compilerFunc
	extern function msArrayDestroy(arr: Ptr<void>): void;

	@compilerFunc
	extern function msArrayWasMoved(arr: Ptr<void>): void;

	@compilerFunc
	extern function msArrayNumberWasMoved(arr: Ptr<void>): void;

	@compilerFunc
	extern function msArrayRefDestroy(arr: Ptr<void>): void;

	@compilerFunc
	extern function msArrayRefWasMoved(arr: Ptr<void>): void;

	@compilerFunc
	extern function msArrayStringDestroy(arr: Ptr<void>): void;

	@compilerFunc
	extern function msArrayStringWasMoved(arr: Ptr<void>): void;

	@compilerFunc
	extern function msArrayUint8Destroy(arr: Ptr<void>): void;

	@compilerFunc
	extern function msArrayUint8WasMoved(arr: Ptr<void>): void;

	@compilerFunc
	extern function msArrayClosureDestroy(arr: Ptr<void>): void;

	@compilerFunc
	extern function msArrayClosureWasMoved(arr: Ptr<void>): void;

	@compilerFunc
	extern function msArrayAtomicRefDestroy(arr: Ptr<void>): void;

	@compilerFunc
	extern function msArrayCopy(d: Ptr<void>, s: Ptr<void>): void;

	@compilerFunc
	extern function msArrayRefCopy(d: Ptr<void>, s: Ptr<void>): void;

	@compilerFunc
	extern function msArrayStringCopy(d: Ptr<void>, s: Ptr<void>): void;

	@compilerFunc
	extern function msArrayUint8Copy(d: Ptr<void>, s: Ptr<void>): void;

	@compilerFunc
	extern function msArrayClosureCopy(d: Ptr<void>, s: Ptr<void>): void;

	@compilerFunc
	extern function msArrayAtomicRefCopy(d: Ptr<void>, s: Ptr<void>): void;

	@compilerFunc
	extern function msArraySetLen(d: Ptr<void>, s: Ptr<void>): void;

	@compilerFunc
	extern function msArrayNumberSink(d: Ptr<void>, v: Ptr<void>): void;

	@compilerFunc
	extern function msArrayRefSink(d: Ptr<void>, v: Ptr<void>): void;

	@compilerFunc
	extern function msArrayStringSink(d: Ptr<void>, v: Ptr<void>): void;

	@compilerFunc
	extern function msArrayUint8Sink(d: Ptr<void>, v: Ptr<void>): void;

	@compilerFunc
	extern function msArrayClosureSink(d: Ptr<void>, v: Ptr<void>): void;

	@compilerFunc
	extern function msNumberArrayDestroy(arr: Ptr<void>): void;

	@compilerFunc
	extern function msRefArrayDestroy(arr: Ptr<void>): void;

	@compilerFunc
	extern function msStringArrayDestroy(arr: Ptr<void>): void;

	@compilerFunc
	extern function msClosureArrayDestroy(arr: Ptr<void>): void;

	@compilerFunc
	extern function msAtomicRefArrayDestroy(arr: Ptr<void>): void;

	@compilerFunc
	extern function msNumberArraySetLen(arr: Ptr<void>, newLen: int64): void;

	@compilerFunc
	extern function msRefArraySetLen(arr: Ptr<void>, newLen: int64): void;

	@compilerFunc
	extern function msStringArraySetLen(arr: Ptr<void>, newLen: int64): void;

	@compilerFunc
	extern function msAtomicRefArraySetLen(arr: Ptr<void>, newLen: int64): void;

	@compilerFunc
	extern function msRefArraySplice(arr: Ptr<void>, start: int64, deleteCount: int64): void;

	@compilerFunc
	extern function msAtomicRefArraySplice(arr: Ptr<void>, start: int64, deleteCount: int64): void;

	@compilerFunc
	extern function msRefArraySplice3(arr: Ptr<void>, start: int64, deleteCount: int64, item: Ptr<void>): void;

	@compilerFunc
	extern function msAtomicRefArraySplice3(arr: Ptr<void>, start: int64, deleteCount: int64, item: Ptr<void>): void;

	@compilerFunc
	extern function msSliceLen(start: int64, end: int64, len: int64): int64;

	@compilerFunc
	extern function msSliceLenUnchecked(start: int64, end: int64, len: int64): int64;

	@compilerFunc
	extern function msClosureCopy(c: () => void): void;

	@compilerFunc
	extern function msClosureDestroy(c: () => void): void;

	@compilerFunc
	extern function msClosureWasMoved(c: () => void): void;

	@compilerFunc
	extern function msClosureSink(d: () => void, v: () => void): void;

	@compilerFunc
	extern function msClosureTrace(c: () => void, env: Ptr<void>): void;

	@compilerFunc
	extern function msSetCard32(v: uint32): int32;

	@compilerFunc
	extern function msSetHashWord(acc: int64, word: uint32): int64;

	@compilerFunc
	extern function msToInt32(x: float64): int32;

	@compilerFunc
	extern function msCheckRangeI8(v: float64, lo: int64, hi: int64): int8;

	@compilerFunc
	extern function msCheckRangeU8(v: float64, lo: int64, hi: int64): uint8;

	@compilerFunc
	extern function msCheckRangeI16(v: float64, lo: int64, hi: int64): int16;

	@compilerFunc
	extern function msCheckRangeU16(v: float64, lo: int64, hi: int64): uint16;

	@compilerFunc
	extern function msCheckRangeI32(v: float64, lo: int64, hi: int64): int32;

	@compilerFunc
	extern function msCheckRangeU32(v: float64, lo: int64, hi: int64): uint32;

	@compilerFunc
	extern function msCheckRangeI64(v: float64): int64;

	@compilerFunc
	extern function msDivI32(a: int32, b: int32): int32;

	@compilerFunc
	extern function msModI32(a: int32, b: int32): int32;

	@compilerFunc
	extern function msPowI32(a: int32, b: int32): int32;

	@compilerFunc
	extern function msPowWrapI32(a: int32, b: int32): int32;

	@compilerFunc
	extern function msDivI64(a: int64, b: int64): int64;

	@compilerFunc
	extern function msModI64(a: int64, b: int64): int64;

	@compilerFunc
	extern function msPowI64(a: int64, b: int64): int64;

	@compilerFunc
	extern function msPowWrapI64(a: int64, b: int64): int64;

	@compilerFunc
	extern function msDivU32(a: uint32, b: uint32): uint32;

	@compilerFunc
	extern function msModU32(a: uint32, b: uint32): uint32;

	@compilerFunc
	extern function msPowU32(a: uint32, b: uint32): uint32;

	@compilerFunc
	extern function msPowWrapU32(a: uint32, b: uint32): uint32;

	@compilerFunc
	extern function msDivU64(a: uint64, b: uint64): uint64;

	@compilerFunc
	extern function msModU64(a: uint64, b: uint64): uint64;

	@compilerFunc
	extern function msPowU64(a: uint64, b: uint64): uint64;

	@compilerFunc
	extern function msPowWrapU64(a: uint64, b: uint64): uint64;

	@compilerFunc
	extern function msDivAssignI32(lv: Ptr<void>, b: Ptr<void>): void;

	@compilerFunc
	extern function msModAssignI32(lv: Ptr<void>, b: Ptr<void>): void;

	@compilerFunc
	extern function msDivAssignI64(lv: Ptr<void>, b: Ptr<void>): void;

	@compilerFunc
	extern function msModAssignI64(lv: Ptr<void>, b: Ptr<void>): void;

	@compilerFunc
	extern function msDivAssignU32(lv: Ptr<void>, b: Ptr<void>): void;

	@compilerFunc
	extern function msModAssignU32(lv: Ptr<void>, b: Ptr<void>): void;

	@compilerFunc
	extern function msDivAssignU64(lv: Ptr<void>, b: Ptr<void>): void;

	@compilerFunc
	extern function msModAssignU64(lv: Ptr<void>, b: Ptr<void>): void;

	@compilerFunc
	extern function msModAssignF64(lv: Ptr<void>, b: Ptr<void>): void;

	@compilerFunc
	extern function msAndAssignF64(lv: Ptr<void>, b: Ptr<void>): void;

	@compilerFunc
	extern function msOrAssignF64(lv: Ptr<void>, b: Ptr<void>): void;

	@compilerFunc
	extern function msXorAssignF64(lv: Ptr<void>, b: Ptr<void>): void;

	@compilerFunc
	extern function msShlAssignF64(lv: Ptr<void>, b: Ptr<void>): void;

	@compilerFunc
	extern function msShrAssignF64(lv: Ptr<void>, b: Ptr<void>): void;

	@compilerFunc
	extern function msShrUAssignF64(lv: Ptr<void>, b: Ptr<void>): void;

	@compilerFunc
	extern function msBoxDouble(v: float64): Ptr<void>;

	@compilerFunc
	extern function msBoxInt32(v: int32): Ptr<void>;

	@compilerFunc
	extern function msBoxBool(v: boolean): Ptr<void>;

	@compilerFunc
	extern function msUnboxDouble(p: Ptr<void>): float64;

	@compilerFunc
	extern function msUnboxInt32(p: Ptr<void>): int32;

	@compilerFunc
	extern function msUnboxBool(p: Ptr<void>): boolean;

	@compilerFunc
	extern function msUnboxString(p: Ptr<void>): string;

	@compilerFunc
	extern function msFutureCreate(): Ptr<void>;

	@compilerFunc
	extern function msFutureComplete(fp: Ptr<void>, val: Ptr<void>): void;

	@compilerFunc
	extern function msFutureCompleteVoid(fp: Ptr<void>): void;

	@compilerFunc
	extern function msFutureFail(fp: Ptr<void>, err: Ptr<void>): void;

	@compilerFunc
	extern function msFutureFinished(fp: Ptr<void>): boolean;

	@compilerFunc
	extern function msFutureDrcDestroy(f: Ptr<void>): void;

	@compilerFunc
	extern function msMaybeAccess(m: Ptr<void>, head: string, labels: string): Ptr<void>;

	@compilerFunc
	extern function msMaybeAccessVal(m: Ptr<void>, head: string, labels: string): Ptr<void>;

	@compilerFunc
	extern function msFutureValueAt(fp: Ptr<void>): Ptr<void>;

	@compilerFunc
	extern function msFutureBoxAt(fp: Ptr<void>): Ptr<void>;

	@compilerFunc
	extern function msFutureOwnsValue(fp: Ptr<void>): boolean;

	@compilerFunc
	extern function msFutureSetValueDrop(fp: Ptr<void>, drop: () => void): void;

	@compilerFunc
	extern function msFutureTakeRaw(fp: Ptr<void>): Ptr<void>;

	@compilerFunc
	extern function msFutureTakeStringRaw(fp: Ptr<void>): string;

	@compilerFunc
	extern function msHcrVariableStorage(cell: Ptr<void>): Ptr<void>;

	@compilerFunc
	extern function msFutureChain(src: Ptr<void>, dst: Ptr<void>): void;

	@compilerFunc
	extern function msFutureChain_double(src: Ptr<void>, dst: Ptr<void>): void;

	@compilerFunc
	extern function msFutureChain_int32(src: Ptr<void>, dst: Ptr<void>): void;

	@compilerFunc
	extern function msFutureChain_int64(src: Ptr<void>, dst: Ptr<void>): void;

	@compilerFunc
	extern function msFutureChain_bool(src: Ptr<void>, dst: Ptr<void>): void;

	@compilerFunc
	extern function msFutureChain_msString(src: Ptr<void>, dst: Ptr<void>): void;

	@compilerFunc
	extern function msFutureChain_ptr(src: Ptr<void>, dst: Ptr<void>): void;

	@compilerFunc
	extern function msFutureThen_double(input: Ptr<void>, onFulfilled: () => void): Ptr<void>;

	@compilerFunc
	extern function msFutureThen_int32(input: Ptr<void>, onFulfilled: () => void): Ptr<void>;

	@compilerFunc
	extern function msFutureThen_int64(input: Ptr<void>, onFulfilled: () => void): Ptr<void>;

	@compilerFunc
	extern function msFutureThen_bool(input: Ptr<void>, onFulfilled: () => void): Ptr<void>;

	@compilerFunc
	extern function msFutureThen_msString(input: Ptr<void>, onFulfilled: () => void): Ptr<void>;

	@compilerFunc
	extern function msFutureThen_ptr(input: Ptr<void>, onFulfilled: () => void): Ptr<void>;

	@compilerFunc
	extern function msFutureThen_ref(input: Ptr<void>, onFulfilled: () => void): Ptr<void>;

	@compilerFunc
	extern function msFutureCatch_double(input: Ptr<void>, onRejected: () => void): Ptr<void>;

	@compilerFunc
	extern function msFutureCatch_int32(input: Ptr<void>, onRejected: () => void): Ptr<void>;

	@compilerFunc
	extern function msFutureCatch_int64(input: Ptr<void>, onRejected: () => void): Ptr<void>;

	@compilerFunc
	extern function msFutureCatch_bool(input: Ptr<void>, onRejected: () => void): Ptr<void>;

	@compilerFunc
	extern function msFutureCatch_msString(input: Ptr<void>, onRejected: () => void): Ptr<void>;

	@compilerFunc
	extern function msFutureCatch_ptr(input: Ptr<void>, onRejected: () => void): Ptr<void>;

	@compilerFunc
	extern function msFutureFinally_double(input: Ptr<void>, onSettled: () => void): Ptr<void>;

	@compilerFunc
	extern function msFutureFinally_int32(input: Ptr<void>, onSettled: () => void): Ptr<void>;

	@compilerFunc
	extern function msFutureFinally_int64(input: Ptr<void>, onSettled: () => void): Ptr<void>;

	@compilerFunc
	extern function msFutureFinally_bool(input: Ptr<void>, onSettled: () => void): Ptr<void>;

	@compilerFunc
	extern function msFutureFinally_msString(input: Ptr<void>, onSettled: () => void): Ptr<void>;

	@compilerFunc
	extern function msFutureFinally_ptr(input: Ptr<void>, onSettled: () => void): Ptr<void>;

	@compilerFunc
	extern function msFutureFinally(input: Ptr<void>, onSettled: () => void): Ptr<void>;

	@compilerFunc
	extern function msFutureThenTyped(input: Ptr<void>, onFulfilled: () => void, typeTag: int32): Ptr<void>;

	@compilerFunc
	extern function msFutureCatchTyped(input: Ptr<void>, onRejected: () => void, typeTag: int32): Ptr<void>;

	@compilerFunc
	extern function msPromiseNew(executor: () => void): Ptr<void>;

	@compilerFunc
	extern function msPromiseResolve(value: Ptr<void>): Ptr<void>;

	@compilerFunc
	extern function msAsyncStart(retFut: Ptr<void>, stepper: () => void): void;

	@compilerFunc
	extern function msWaitFor(fut: Ptr<void>): Ptr<void>;

	@compilerFunc
	extern function msWaitForReady(fut: Ptr<void>): void;

	@compilerFunc
	extern function msMonoTimeMs(): int64;

	@compilerFunc
	extern function msSpawn(fn: () => void): Ptr<void>;

	@compilerFunc
	extern function msSpawnSlotSubmit(s: Ptr<void>, slot: int32, fn: () => void): void;

	@compilerFunc
	extern function msSpawnTaskSubmit(group: Ptr<void>, slot: int32, fn: () => void): void;

	@compilerFunc
	extern function msSpawnCheckCancel(g: Ptr<void>): boolean;

	@compilerFunc
	extern function msAwaitGroupInit(n: int32): Ptr<void>;

	@compilerFunc
	extern function msAwaitGroupBlocking(g: Ptr<void>): void;

	@compilerFunc
	extern function msAwaitGroupCancel(g: Ptr<void>): void;

	@compilerFunc
	extern function msAwaitGroupFree(g: Ptr<void>): void;

	@compilerFunc
	extern function msAwaitGroupBlockingWithDeadline(g: Ptr<void>, deadlineMs: int64): void;

	@compilerFunc
	extern function msAwaitGroupResult(g: Ptr<void>, slot: int32): Ptr<void>;

	@compilerFunc
	extern function msAwaitGroupSetDoneFut(g: Ptr<void>, fut: Ptr<void>): void;

	@compilerFunc
	extern function msAwaitGroupTimedOut(g: Ptr<void>): boolean;

	@compilerFunc
	extern function msAwaitSlotCreate(n: int32): Ptr<void>;

	@compilerFunc
	extern function msAwaitSlotRelease(sp: Ptr<void>): void;

	@compilerFunc
	extern function msAwaitSlotWait(sp: Ptr<void>): void;

	@compilerFunc
	extern function msActorCreatePid(state: Ptr<void>, dispatch: Ptr<void>): int64;

	@compilerFunc
	extern function msActorFromPid(pid: int64): Ptr<void>;

	@compilerFunc
	extern function msActorPollAll(): boolean;

	@compilerFunc
	extern function msActorRegister(a: Ptr<void>): void;

	@compilerFunc
	extern function msActorSend(a: Ptr<void>, msg: Ptr<void>): void;

	@compilerFunc
	extern function msActorSuspend(a: Ptr<void>, implFut: Ptr<void>, replyFut: Ptr<void>): void;

	@compilerFunc
	extern function msActorTrapExits(pid: int64, trap: boolean): void;

	@compilerFunc
	extern function msActorSetOnTerminate(actor: Ptr<void>, fn: Ptr<void>): void;

	@compilerFunc
	extern function msActorSetSystemMsgHandler(actor: Ptr<void>, fn: Ptr<void>): void;

	@compilerFunc
	extern function msMsgAllocSized(kind: int32, replyFut: Ptr<void>, argCount: int32): Ptr<void>;

	@compilerFunc
	extern function msMsgKind(msg: Ptr<void>): int32;

	@compilerFunc
	extern function msMsgReplyFuture(msg: Ptr<void>): Ptr<void>;

	@compilerFunc
	extern function msMsgGetDouble(m: Ptr<void>, idx: int32): float64;

	@compilerFunc
	extern function msMsgGetInt32(m: Ptr<void>, idx: int32): int32;

	@compilerFunc
	extern function msMsgGetInt64(m: Ptr<void>, idx: int32): int64;

	@compilerFunc
	extern function msMsgGetBool(m: Ptr<void>, idx: int32): boolean;

	@compilerFunc
	extern function msMsgGetString(m: Ptr<void>, idx: int32): string;

	@compilerFunc
	extern function msMsgGetPtr(m: Ptr<void>, idx: int32): Ptr<void>;

	@compilerFunc
	extern function msMsgSetDouble(m: Ptr<void>, idx: int32, val: float64): void;

	@compilerFunc
	extern function msMsgSetInt32(m: Ptr<void>, idx: int32, val: int32): void;

	@compilerFunc
	extern function msMsgSetInt64(m: Ptr<void>, idx: int32, val: int64): void;

	@compilerFunc
	extern function msMsgSetBool(m: Ptr<void>, idx: int32, val: boolean): void;

	@compilerFunc
	extern function msMsgSetString(m: Ptr<void>, idx: int32, s: string): void;

	@compilerFunc
	extern function msMsgSetPtr(m: Ptr<void>, idx: int32, val: Ptr<void>): void;

	@compilerFunc
	extern function msMsgSetPtrShared(m: Ptr<void>, idx: int32, val: Ptr<void>): void;

	@compilerFunc
	extern function msPrintln(s: string): void;

	@compilerFunc
	extern function __FILE__(): cstring from "__FILE__";

	@compilerFunc
	extern function strlen(s: cstring): uint64;

	// ===== Power-assert reporting (runtime/core/test.h) =====

	@compilerFunc
	extern function __paBegin(source: cstring): void;

	@compilerFunc
	extern function __paEnd(): void;

	@compilerFunc
	extern function __paValueStr(col: int32, label: cstring, val: cstring): void;

	@compilerFunc
	extern function __paValueNum(col: int32, label: cstring, val: float64): void;

	@compilerFunc
	extern function __paValueInt(col: int32, label: cstring, val: int64): void;

	@compilerFunc
	extern function __paValueBool(col: int32, label: cstring, val: int32): void;
}

// ===== Derived comparison operators (standard library parity) =====
// Given ==, < and <= for a type, derive !=, > and >= at zero cost.
// `<=` stays a per-type base operator: deriving it as !(b < a) only holds for a
// total order, and silently inverts the answer for partial ones (NaN, subset).
export template `!=`<T>(a: T, b: T): boolean { return !(a == b); }
export template `>`<T>(a: T, b: T): boolean { return b < a; }
export template `>=`<T>(a: T, b: T): boolean { return b <= a; }

