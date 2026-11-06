import { Handle } from "std/ffi";

export struct P { x: int32; }

@wasm
export function open(start: int32): Handle<P> {
	return Handle.at<P>(null as Ptr<void>);
}
