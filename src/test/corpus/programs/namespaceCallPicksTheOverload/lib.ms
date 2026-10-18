export function tag(n: int32): string { return `n${n}`; }
export function tag(s: string): string { return `s${s}`; }
export function tag(a: int32, b: int32): string { return `p${a + b}`; }
export function size(s: string): string { return `t${s.length}`; }
export function size<T>(xs: T[]): string { return `a${xs.length}`; }
export function solo(n: int32): string { return `o${n}`; }
