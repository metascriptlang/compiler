// @stdout: 7
// @stdout: end
// note: a call through a narrowed `(() => T) | null` field inside a generic is a call through a value on every backend.
// The instance's field symbol carries its type's name as `nativeName`, and the Raiser read that as an extern routine
// ("Unknown host function: Maybe_fn_fnint3210"); only a routine symbol is a host call, a property never is.

interface Src<T> {
	stop: (() => T) | null;
}

function close<T>(s: Src<T>): void {
	if (s.stop != null) console.log(s.stop());
}

close<int32>({ stop: (): int32 => 7 });
close<int32>({ stop: null });
console.log("end");
