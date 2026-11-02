@include("runtime/core/system.h");
@compile("runtime/core/system.c");
@compile("runtime/drc.c");

export { console, process, setTimeout, clearTimeout, setInterval, clearInterval, compilerFunc, throws, delegate, msCharToString, AbortSignal } from "./kernel";
import { AbortSignal } from "./kernel";

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

