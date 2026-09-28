// nim-guard: an object handed to C through Handle<T> lives exactly as long as the handle's count.
//
// Reference: GC_ref / GC_unref (lib/system/arc.nim:301-306) — +1 while foreign code
// holds the address, -1 when it gives it back; Swift Unmanaged passRetained /
// takeRetainedValue / release have the same shape. The MetaScript owner is gone
// before C returns the address, so only the handle's +1 keeps the object alive.
// Proven red with msFfiRetain made a no-op (DOUBLE-DESTROY of View on the release
// in reclaim) and with msFfiRelease made a no-op (View alloc=300 destroy=0).
//
// RED MEANS Handle.retain / release / take stopped balancing the object's count;
// run /trace-nim on View and check std/ffi against runtime msFfiRetain/msFfiRelease.
//
// GUARD-BALANCE View

@compile("./fixtures/handleKeeper.c");

import { Handle } from "std/ffi";
import { msTestKeep, msTestKept } from "./fixtures/handleKeeper.h";

class View {
	name: string;
	constructor(name: string) { this.name = name; }
}

function hand(i: int32): void {
	const v = new View("v" + i.toString());
	msTestKeep(Handle.retain(v).ptr);
}

function reclaim(): string {
	const h = Handle.at<View>(msTestKept());
	const name = h.value().name;
	h.release();
	return name;
}

function takeBack(i: int32): int32 {
	hand(i);
	const v = Handle.at<View>(msTestKept()).take();
	return v.name.length as int32;
}

function main(): void {
	let last = "";
	let lengths = 0 as int32;
	for (let i = 0; i < 200; i += 1) {
		hand(i as int32);
		last = reclaim();
	}
	for (let i = 0; i < 100; i += 1) lengths += takeBack(i as int32);
	console.log(`handle-keeps ${last} ${lengths}`);
}
main();
