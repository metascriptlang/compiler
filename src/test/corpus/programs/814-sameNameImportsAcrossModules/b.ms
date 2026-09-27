export const LIMIT: int32 = 40;
export enum Mode { Slow, Fast, Off }
export function describe(m: Mode): string { return m == Mode.Off ? "b-off" : "b-on"; }
