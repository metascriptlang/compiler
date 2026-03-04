@include("system.h");

class console {
  @runtime("msPrintln")
  log(value: string): void { unreachable; }
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
