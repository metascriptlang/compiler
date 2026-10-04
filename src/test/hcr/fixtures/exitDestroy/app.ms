import { reload } from "std/hcr";
import { keeper } from "./logic";

class Note {
	text: string;

	constructor(text: string) {
		this.text = text;
	}

	onDestroy(): void {
		console.log(`EXIT destroy ${this.text}`);
	}
}

const own = new Note("app");
reload();
console.log(`EXIT run ${own.text} ${keeper.text}`);
