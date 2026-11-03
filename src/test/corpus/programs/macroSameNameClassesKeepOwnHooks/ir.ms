export enum Stage { Vertex, Fragment }

export struct Pair {
	name: string;
	unit: int32;
}

export class Body {
	lines: string[] = [];
	depth: int32 = 0;
}
