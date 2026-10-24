export class Box {
	n: int32 = 1;
	extra: int32 = 2;
}

export function make(): Box { return new Box(); }
