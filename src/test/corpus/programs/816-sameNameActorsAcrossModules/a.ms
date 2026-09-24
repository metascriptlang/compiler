actor Counter { n: int32 = 0; bump(): int32 { this.n = this.n + 1; return this.n; } }
export async function fromA(): Promise<string> { const c = new Counter(); const v = await c.bump(); return "A" + String(v); }
