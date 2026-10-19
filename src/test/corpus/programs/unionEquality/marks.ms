export type Mark = int32 | string;
export function markOf(n: int32): Mark { return n; }
export function markOfText(s: string): Mark { return s; }
