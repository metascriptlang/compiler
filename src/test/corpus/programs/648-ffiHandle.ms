// @stdout: ffi-handle value=parked at=parked took=parked rounds=300 plain=plain
// @xfail(raiser): std/ffi binds C and JS only; comptime holds no foreign address to hand out

import { Handle } from "std/ffi";

class View {
	name: string;
	constructor(name: string) { this.name = name; }
}

function park(): Handle<View> {
	return Handle.retain(new View("parked"));
}

function round(): string {
	const h = park();
	const seen = h.value().name;
	const again = Handle.at<View>(h.ptr);
	again.retain();
	again.release();
	const took = h.take();
	return seen == took.name ? took.name : "mismatch";
}

function main(): void {
	const plain = new View("plain");
	const first = park();
	const value = first.value().name;
	const at = Handle.at<View>(first.ptr).value().name;
	const took = first.take().name;
	let rounds = 0 as int32;
	for (let i = 0; i < 300; i += 1) {
		if (round() == "parked") rounds += 1;
	}
	console.log(`ffi-handle value=${value} at=${at} took=${took} rounds=${rounds} plain=${plain.name}`);
}
main();
