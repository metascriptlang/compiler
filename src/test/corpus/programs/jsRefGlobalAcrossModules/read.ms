import { pool } from "./pool";

export function readNamed(): int32 { return pool.count + pool.slots.length; }
