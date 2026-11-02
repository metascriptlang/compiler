let order: string = "";

export class Logger {
	text: string = "";
	count: int32 = 0;
	add(word: string): void {
		this.text = this.text + " " + word;
		this.count += 1;
	}
	reset(): void {
		this.text = "";
		this.count = 0;
	}
}

export class Tracker {
	name: string;
	constructor(name: string) { this.name = `${name}`; }
	rename(name: string): void { this.name = name + ""; }
	onDestroy(): void {
		order = order + " " + this.name;
		if (this.name == "g") console.log("destroy order" + order);
	}
}
