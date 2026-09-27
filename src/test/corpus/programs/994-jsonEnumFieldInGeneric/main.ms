// @stdout: {"p":{"c":"Green","x":4},"cs":["Red","Blue"],"s":"Inactive"}
import { Pixel, Frame } from "./shapes";

function run(): void {
	const p = JSON.parse<Pixel>(`{"c":"Blue","x":3}`);
	console.log(p.ok ? JSON.stringify(p.value) : `err ${p.error}`);
	const f = JSON.parse<Frame>(`{"p":{"c":"Green","x":4},"cs":["Red","Blue"],"s":"Inactive"}`);
	console.log(f.ok ? JSON.stringify(f.value) : `err ${f.error}`);
	const bad = JSON.parse<Pixel>(`{"c":2,"x":3}`);
	console.log(bad.ok ? "accepted" : bad.error);
}

run();
