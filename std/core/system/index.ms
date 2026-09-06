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

extern function msAbortThrow(): void from "msAbortThrow";

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
// Given == and < for any type, derive !=, >, <=, >= at zero cost.
export template `!=`<T>(a: T, b: T): boolean { return !(a == b); }
export template `>`<T>(a: T, b: T): boolean { return b < a; }
export template `<=`<T>(a: T, b: T): boolean { return !(b < a); }
export template `>=`<T>(a: T, b: T): boolean { return !(a < b); }

