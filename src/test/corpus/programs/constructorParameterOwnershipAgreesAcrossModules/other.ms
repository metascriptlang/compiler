import { P, Cell, Quick, Base } from "./lib";

export class Wide extends Base {
	constructor(item: P, up: P) { super(item, up); }
}

export function fromOther(): string {
	const o1 = new P("o");
	const c = new Cell<P>(new P("a"), o1);
	const o2 = new P("p");
	const s = new Cell<string>("s", o2);
	const o3 = new P("q");
	const q = new Quick<P>(new P("d"), o3);
	return c.value.name + c.up!.name + s.value + s.up!.name + q.value.name + q.up!.name;
}
