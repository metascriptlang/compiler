@include("system.h");

export class console {
  @builtin("Echo")
  static extern log(value: string): void from "msPrintln";
}

export class Result<T, E> {
	static extern ok(val: T): Result<T, E>;
	static extern err(e: E): Result<T, E>;
}

extern function toString(this val: number): string from "msIntToStr";
extern function toString(this val: bool): string from "msBoolToStr";

