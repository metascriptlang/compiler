const prefix: string = ["fd", ":"].join("");

export type Fd = distinct int32;

export function onDestroy(this x: Fd): void {
	console.log("hook " + prefix + (x as int32).toString());
}
