const prefix: string = ["inner", ":"].join("");

export struct Inner { v: int32; }

export function onDestroy(this x: Inner): void {
	console.log("hook " + prefix + x.v.toString());
}
