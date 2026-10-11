interface Hidden { v: int32 }
export type Public = Hidden;
export function fromInt<T>(value: int32): T { return { v: value } as T; }
