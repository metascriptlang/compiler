export struct Cell<T> { v: T; }

export function onDestroy(this x: Cell<int32>): void {
	console.log("cell " + x.v.toString());
}
