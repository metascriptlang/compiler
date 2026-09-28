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

@compilerFunc @throws
extern function msAssertFail(msg: cstring, file: cstring, line: int32): void from "msAssertFail";

@compilerFunc @throws
extern function msAwaitSlotResult(slot: Ptr<void>): Ptr<void> from "msAwaitSlotResult";

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

// ===== Derived comparison operators (standard library parity) =====
// Given ==, < and <= for a type, derive !=, > and >= at zero cost.
// `<=` stays a per-type base operator: deriving it as !(b < a) only holds for a
// total order, and silently inverts the answer for partial ones (NaN, subset).
export template `!=`<T>(a: T, b: T): boolean { return !(a == b); }
export template `>`<T>(a: T, b: T): boolean { return b < a; }
export template `>=`<T>(a: T, b: T): boolean { return b <= a; }

