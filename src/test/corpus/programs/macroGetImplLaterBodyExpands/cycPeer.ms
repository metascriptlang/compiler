import { typed } from "./meta";
import { viaCycle } from "./cyc";

export function fromPeer(): int32 { return typed(11); }
export function peerSees(): int32 { return viaCycle(); }
