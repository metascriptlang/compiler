export function trav(items: string[]): string {
	let joined = "";
	let count = 0;
	const add = (s: string): void => {
		joined = joined + s;
		count = count + 1;
	};
	for (const s of items) add(s);
	return `${joined}:${count}`;
}
