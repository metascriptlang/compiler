export struct Box { n: int32; }

export function data(this box: Box): int32 { return box.n; }

export function plain(x: int32): int32 { return x * 2; }

export function make(): Box { return { n: 7 }; }
