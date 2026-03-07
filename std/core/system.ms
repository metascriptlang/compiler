@include("system.h");

class console {
  extern log(value: string): void from "msPrintln";
}

export interface Result<T, E> {
	ok: boolean;
	value: T;
	error: E;
}

@builtin("msResultOk")
export function ok<T, E>(this typeof Result, val: T): Result<T, E> {
	unreachable;
}

@builtin("msResultErr")
export function err<T, E>(this typeof Result, e: E): Result<T, E> {
	unreachable;
}

@builtin("Expect")
export function expect(cond: boolean): void {
	unreachable;
}

@builtin("Expect")
export function expect(cond: boolean, msg: string): void {
	unreachable;
}
