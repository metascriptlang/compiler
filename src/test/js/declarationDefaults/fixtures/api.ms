export type Pair<T extends string = string, U = T[], V = [T, U]> = [T, U, V];
export interface Box<T = string, U = T[]> { value: T; values: U; }
export struct Cell<T = int32> { value: T; }
export function increment(value: int32): int32 { return value + 1; }
