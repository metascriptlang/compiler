export function `/`(this a: int32, b: int32): int32 { return a * 100 + b; }
export function `/=`(this ref a: int32, b: int32): void { a = -a - b; }
export function `%`(this a: int64, b: int64): int64 { return 77; }
export function opsTag(): string { return "ops"; }
