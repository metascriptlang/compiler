import { later, wrap } from "./a";
class Box { v: int32 = 7; }
class Box8 { v: int32 = 8; }
export function run(): void {
	const list: Box[] = [new Box()];
	const item = list[0];
	later((): void => { console.log(item.v); });
	list.pop();
	const more: Box8[] = [new Box8()];
	const other = more[0];
	wrap((): void => { console.log(other.v); });
	more.pop();
}
