class Box { v: int32; constructor(v: int32) { this.v = v; } }
export function fromB(): int32 { const b = new Box(2); return b.v; }
