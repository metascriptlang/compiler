export type Either<T> = T | string;
export type Opt<T> = T | null;
export type Both<T> = Either<T> | null;

export function describe(e: Either<int32>): string {
	if (typeof e === "string") return "s:" + e;
	return "n:" + `${e + 1}`;
}

export type Tree<T> = { kind: "leaf"; v: T } | { kind: "node"; l: Tree<T>; r: Tree<T> };

export function total(t: Tree<int32>): int32 {
	if (t.kind == "leaf") return t.v;
	return total(t.l) + total(t.r);
}
