export struct Meta { key: uint64; }
export function writable(index: int32): int32 { return index + 1; }
export function writable(this typeof Meta, key: uint64): Meta { return { key }; }
