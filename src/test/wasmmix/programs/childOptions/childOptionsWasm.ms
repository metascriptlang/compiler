import { define } from "std/meta";

@wasm
export function targetFlags(): int32 {
	let flags: int32 = 0;
	when (probeMarker) { flags += 1; }
	when (c) { flags += 2; }
	when (emcc) { flags += 4; }
	when (!js) { flags += 8; }
	return flags;
}

@wasm
export function label(): string {
	return @comptime { return define("label"); };
}

@wasm
export function projectDirectory(): string {
	return @comptime { return define("projectDir"); };
}

@wasm
export function emptyValue(): string {
	return @comptime { return define("empty"); };
}
