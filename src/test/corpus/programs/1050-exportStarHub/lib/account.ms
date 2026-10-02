export struct Account { address: uint64; }
export function key(this a: Account): uint64 { return a.address * 2; }
export function make(): int32 { return 8; }
