export struct Opts { level: int32; }
export function greet(name: string, opts: Opts = { level: 1 }): int32 { return name.length as int32 + opts.level; }
export function scale(n: int32, by: int32 = 2): int32 { return n * by; }
