export class Holder {
	name: string = "";
}

export let label: string = "";
export const holder = new Holder();

export function fill(n: int32): void {
	label = `label-${n}`;
	holder.name = `field-${n}`;
}
