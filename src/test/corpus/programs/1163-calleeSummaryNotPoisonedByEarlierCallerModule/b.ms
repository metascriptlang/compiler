import { Box, Wrapper, hidden } from "./a";
export function run(): void {
	const w = new Wrapper();
	w.items.push(new Box());
	hidden(w);
}
