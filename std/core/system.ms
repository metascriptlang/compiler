@include("system.h");

export class console {
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

