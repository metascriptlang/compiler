export struct Cell { text: string; }

export function labels(n: int32): Cell[] {
	return [{ text: "alpha" + n }, { text: "beta" + n }];
}
