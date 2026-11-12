import { P, Hold } from "./a";

export class Leaf {
	up: Unowned<P> | null;
	constructor(up: P) { this.up = up; }
}

export class Keep {
	hold: Hold;
	up: Unowned<P> | null;
	constructor(p: P) { this.hold = new Hold(p); this.up = p; }
}

export function viaKeep(): string {
	const p = new P("k");
	const k = new Keep(p);
	return k.hold.item.name + k.up!.name;
}
