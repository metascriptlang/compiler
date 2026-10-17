let order: string = "";

export class Tracker {
	name: string;
	constructor(name: string) { this.name = name; }
	onDestroy(): void {
		order = order + " " + this.name;
		if (this.name == "eager") console.log("destroy order" + order);
	}
}
