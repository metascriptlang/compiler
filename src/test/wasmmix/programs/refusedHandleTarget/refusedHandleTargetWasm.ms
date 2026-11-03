import { Handle } from "std/ffi";

@wasm
export function open(start: int32): Handle<int32> {
	return Handle.retain(start);
}
