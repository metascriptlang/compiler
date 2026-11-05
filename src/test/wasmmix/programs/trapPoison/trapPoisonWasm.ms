when (c) {
	extern function nativeTrap(): void from "__builtin_trap";
}

@wasm
export function trapNow(): void {
	when (c) {
		nativeTrap();
	} else {
		throw new Error("native trap");
	}
}

@wasm
export function ping(): int32 {
	return 7;
}
