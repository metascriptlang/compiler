export class Session {
	private count: int32 = 2;
	bump(by: int32): int32 { this.count += by; return this.count; }
}
