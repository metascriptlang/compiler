class Box { v: int32; constructor(v: int32) { this.v = v; } }
const kept = new Box(1);
export function fromA(): int32 { return kept.v; }
