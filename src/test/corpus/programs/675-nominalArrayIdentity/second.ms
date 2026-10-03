export struct Cell { count: int32; }

export function makeSecond(n: int32): Cell[] {
	return [{ count: n }];
}
