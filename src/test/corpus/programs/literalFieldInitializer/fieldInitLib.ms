const SECRET: int32 = 41;
let made: int32 = 0;

export function mk(): int32[] {
	made += 1;
	return [made];
}

export function madeCount(): int32 {
	return made;
}

export class Base {
	tag: string = "base";
	secret: int32 = SECRET + 1;
}

export class Lib extends Base {
	ys: int32[] = mk();
	n: int32;
}
