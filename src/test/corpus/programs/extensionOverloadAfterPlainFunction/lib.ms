export function tag(n: int32): string { return `n${n}`; }
export function tag(this s: string): string { return `s${s}`; }
export function tag(this n: float64, k: int32): string { return `f${k}`; }
export function label(): string { return "ns"; }
