struct Guard { id: int32; }

function onDestroy(this g: Guard): void {
	if (g.id != 0) console.log(`guard ${g.id} released`);
}

class Owner { id: int32 = 0; }

function onDestroy(this o: Owner): void {
	if (o.id != 0) console.log(`owner ${o.id} released`);
}

let kept: () => int32 = (): int32 => 0;

@wasm
export function keepGuard(id: int32): void {
	const g: Guard = { id: id };
	kept = (): int32 => g.id;
}

@wasm
export function keepOwner(id: int32): void {
	const o = new Owner();
	o.id = id;
	kept = (): int32 => o.id;
}

@wasm
export function callKept(): int32 {
	return kept();
}

@wasm
export function clearKept(): void {
	kept = (): int32 => 0;
}
