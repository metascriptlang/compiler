import { Box, Wrapper, process } from "./a";
export function run(): void {
	const w = new Wrapper();
	w.items.push(new Box());
	process(w.items[0], w);
}
