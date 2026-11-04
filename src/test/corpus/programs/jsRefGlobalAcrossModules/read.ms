import { pool, total } from "./pool";

export function readNamed(): int32 { return pool.count + pool.slots.length; }
export function readTotal(): int32 { return total; }
