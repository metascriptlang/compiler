export enum Mode { Fast, Slow }

export type Id = distinct int32;

export function toString(this m: Mode): string { return m == Mode.Fast ? "a-fast" : "a-slow"; }

export function toString(this i: Id): string { return "id#" + String(i as int32); }

export function fastA(): Mode { return Mode.Fast; }

export function idA(): Id { return 7 as Id; }
