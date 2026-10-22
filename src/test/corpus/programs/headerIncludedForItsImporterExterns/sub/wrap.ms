import { imported } from "./lib.h";
extern function sumBytes(bytes: Readonly<Span<uint8>>): int64;
extern const libLimit: int32;

export function viaImported(): int32 { return imported(); }
export function viaSum(data: uint8[]): int64 { return sumBytes(data); }
export function limit(): int32 { return libLimit; }
