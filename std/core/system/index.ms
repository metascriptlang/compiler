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
	static extern log(value: string): void from "msPrintln";
}

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
// TODO: Template version causes DRC double-free on large compilations.
// Template expansion inlines code → DRC may double-manage expanded params.
// Using regular functions until template+DRC interaction is fixed.
export function `!=`<T>(a: T, b: T): boolean { return !(a == b); }
export function `>`<T>(a: T, b: T): boolean { return b < a; }
export function `<=`<T>(a: T, b: T): boolean { return !(b < a); }
export function `>=`<T>(a: T, b: T): boolean { return !(a < b); }

