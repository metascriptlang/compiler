import { twice } from "../main";

export function half() { return twice() / 2 + extra(); }
function extra() { return 0.5; }

export class Halver {
	plusOne() { return this.value() + 1; }
	value() { return half(); }
}
