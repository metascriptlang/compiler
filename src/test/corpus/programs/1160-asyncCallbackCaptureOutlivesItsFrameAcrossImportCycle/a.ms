import { run } from "./b";
class Pad { v: int32 = 99; }
const keep: Pad[] = [];
export async function later(f: () => void): Promise<void> {
	await Promise.resolve(0);
	f();
}
export function wrap(f: () => void): void {
	later(f);
}
export function again(): void {
	run();
	for (let i = 0; i < 64; i++) keep.push(new Pad());
}
