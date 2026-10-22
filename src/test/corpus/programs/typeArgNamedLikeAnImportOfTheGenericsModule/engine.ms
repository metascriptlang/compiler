import { Row } from "./rows";
import { hold } from "./cell";

export class ListCell {
	k: int32;
	constructor(k: int32) {
		this.k = k;
	}
}

export function ownRows(): int32 {
	const [get, set] = hold<Row[]>([{ n: 1 }]);
	return get()[0].n + new ListCell(1).k;
}

export function engine<T>(items: T[]): T[] {
	const make = (k: int32): () => T[] => {
		const [get, set] = hold<T[]>(items);
		return get;
	};
	return make(0)();
}
