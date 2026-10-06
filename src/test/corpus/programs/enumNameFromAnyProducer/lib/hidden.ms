enum Mode { Off, On, Auto }

export function describe(n: int32): string {
	const m = n as Mode;
	return m.toString();
}
