export type Mutable<T> = distinct T;
export function data<T>(this p: Mutable<T>): uint64 { return sizeof(T) as uint64; }
