export struct P { x: int32; y: int32; }
export function bump(p: P): int32 { p = { x: p.x + 1, y: p.y }; return p.x + p.y; }
export function twice(f: (n: int32) => int32): int32 { const g = f; f = (n: int32): int32 => g(g(n)); return f(1); }
