export const LIMIT: int32 = 3;
export enum Mode { Fast, Slow }
export function describe(m: Mode): string { return m == Mode.Fast ? "a-fast" : "a-slow"; }
