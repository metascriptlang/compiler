actor Counter { n: int32 = 10; bump(): int32 { this.n = this.n + 5; return this.n; } }
export async function fromB(): Promise<string> { const c = new Counter(); const v = await c.bump(); return "B" + String(v); }
