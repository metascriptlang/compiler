export class Ctx<T> {
	v: T;
	constructor(v: T) { this.v = v; }
}

export function createCtx<T>(v: T): Ctx<T> { return new Ctx<T>(v); }

export const Scope = createCtx<string>("s");
