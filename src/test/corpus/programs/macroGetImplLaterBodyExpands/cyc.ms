import { hasImpl, twice } from "./meta";
import { fromPeer } from "./cycPeer";

export function viaCycle(): int32 { return hasImpl(fromPeer); }
export function fromCycle(): int32 { return twice(fromPeer()); }
