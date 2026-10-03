export struct Account { address: uint64; }
export function key(this a: Account): uint64 { return a.address * 2; }
