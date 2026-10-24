function secret(): int32 { return 1; }
const base: int32 = 10;

export template viaSecret(): int32 { return secret(); }
export template plusBase(x: int32): int32 { return x + base; }
export template logBase(): void {
	console.log(`base=${base}`);
}
