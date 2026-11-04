import * as P from "./pool";

export function readThroughNamespace(): int32 { return P.pool.count + P.pool.slots.length + P.total; }
