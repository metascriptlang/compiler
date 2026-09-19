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
extern function msAwaitSlotResult(slot: unknown): unknown from "msAwaitSlotResult";

@throws
extern function msAbortThrow(): void from "msAbortThrow";

@compilerFunc
extern function msFutureCompleteT(fut: unknown, sink value: unknown): void from "msFutureCompleteT";

@compilerFunc @builtin("SpawnInto")
extern function msSpawnInto(sink fut: unknown, fn: unknown): unknown;

@compilerFunc @builtin("FutureCreateInline")
extern function msFutureCreateInline(): unknown;

@compilerFunc @builtin("WaitForStruct")
extern function msWaitForStruct(fut: unknown): unknown;

@compilerFunc @builtin("BoxStruct")
extern function msBoxStruct(val: unknown): unknown;

@compilerFunc @builtin("SinkBoxStruct")
extern function msSinkBoxStruct(val: unknown): unknown;

@compilerFunc @builtin("UnboxStruct")
extern function msUnboxStruct(box: unknown): unknown;

@compilerFunc @builtin("BoxRefArray")
extern function msBoxRefArray(arr: unknown): unknown;

@compilerFunc @builtin("BoxArc")
extern function msBoxArc(val: unknown): unknown;

@compilerFunc @builtin("BoxLocked")
extern function msBoxLocked(val: unknown): unknown;

@compilerFunc @builtin("StringConcatArr")
extern function msStringConcatArr(count: int32, ...parts: string[]): string;

@compilerFunc @builtin("StringAppendArr")
extern function msStringAppendArr(dest: unknown, count: int32, ...parts: string[]): void;

@compilerFunc @builtin("StringArrayFromArr")
extern function msStringArrayFromArr(count: int32, ...parts: string[]): string[];

@compilerFunc @builtin("NumberArrayFrom")
extern function msNumberArrayFrom(count: int32, ...values: float64[]): float64[];

@compilerFunc
extern function msMsgCompleteDouble(fut: unknown, sink val: float64): void from "msMsgCompleteDouble";

@compilerFunc
extern function msMsgCompleteInt32(fut: unknown, sink val: int32): void from "msMsgCompleteInt32";

@compilerFunc
extern function msMsgCompleteInt64(fut: unknown, sink val: int64): void from "msMsgCompleteInt64";

@compilerFunc
extern function msMsgCompleteBool(fut: unknown, sink val: boolean): void from "msMsgCompleteBool";

@compilerFunc
extern function msMsgCompletePtr(fut: unknown, sink val: unknown): void from "msMsgCompletePtr";

@compilerFunc
extern function msMsgCompleteString(fut: unknown, sink val: string): void from "msMsgCompleteString";

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

