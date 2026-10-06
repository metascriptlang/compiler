export interface Bag { items: number[] }
export interface Names { list: string[] }
export interface Pt { label: string; x: int32 }
export interface Path { pts: Pt[] }

export function resetBag(b: Bag): void {
	b.items = [];
}

export function resetNames(n: Names): void {
	n.list = [];
}

export function resetPath(p: Path): void {
	p.pts = [];
}

export function namesOf<T>(seed: T): Names {
	return { list: [`${seed}`] };
}
