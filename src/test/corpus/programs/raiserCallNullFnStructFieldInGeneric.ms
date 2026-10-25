// @stdout: stopped 3
// @stdout: end
// note: the struct-returning variant of raiserCallNullFnFieldInGeneric, with the struct itself generic.

interface Res<T> {
	value: T;
}

interface Src<T> {
	stop: (() => Res<T>) | null;
}

function close<T>(s: Src<T>): void {
	if (s.stop != null) console.log(`stopped ${s.stop().value}`);
}

close<int32>({ stop: (): Res<int32> => ({ value: 3 }) });
close<int32>({ stop: null });
console.log("end");
