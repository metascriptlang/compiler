class Counter { n: int32 = 100; bump(): int32 { this.n = this.n + 1; return this.n; } }
export function fromC(): string { const c = new Counter(); return "C" + String(c.bump()); }
