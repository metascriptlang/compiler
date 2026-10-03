export class Keeper {
	text: string;

	constructor(text: string) {
		this.text = text;
	}

	onDestroy(): void {
		console.log(`EXIT destroy ${this.text}`);
	}
}

export const keeper = new Keeper("logic");
