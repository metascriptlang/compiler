import { Wrapper, hidden } from "./a";
export function run(): void {
	const w = new Wrapper();
	w.name = "old" + String(w.name.length);
	w.name += hidden(w);
	console.log(w.name);
}
