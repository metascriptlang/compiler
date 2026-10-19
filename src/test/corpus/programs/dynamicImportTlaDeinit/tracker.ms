let order: string = "";
let started: string = "";

export function note(step: string): void {
	started = started + " " + step;
	console.log(step);
}

export function steps(): string { return started; }

export class Tracker {
	name: string;
	constructor(name: string) { this.name = name; }
	onDestroy(): void {
		order = order + " " + this.name;
		if (this.name == "eager") console.log("destroy order" + order);
	}
}
