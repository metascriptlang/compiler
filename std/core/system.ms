@include("system.h");

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
	/** Creates a successful Result wrapping the given value. */
	static extern ok(val: T): Result<T, E>;
	/** Creates an error Result wrapping the given error. */
	static extern err(e: E): Result<T, E>;
}


