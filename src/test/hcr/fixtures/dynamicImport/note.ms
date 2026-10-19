export class Note {
	name: string;

	constructor(name: string) {
		this.name = name;
	}

	onDestroy(): void {
		console.log(`DYN destroy ${this.name}`);
	}
}
