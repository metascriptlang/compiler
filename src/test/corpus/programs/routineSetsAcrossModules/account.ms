export struct Account { address: uint64; }
export function key(a: Account): uint64 { return a.address * 2; }
