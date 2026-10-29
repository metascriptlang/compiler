// @stdout: 2 1 2 1|3 2

@passC("-Werror=incompatible-pointer-types");

enum K { Click, Key, Wheel }
interface Click { kind: K.Click; x: int32; }
interface Key { kind: K.Key; code: int32; }
interface Wheel { kind: K.Wheel; dy: int32; }
type Ev = Click | Key;
type Ev3 = Click | Key | Wheel;

function make(a: int32): Ev {
	if (a > 0) return { kind: K.Click, x: a };
	return { kind: K.Key, code: a };
}

function weigh(v: Click | Key): int32 {
	return v.kind == K.Key ? 2 : 1;
}

function back(e: Ev): Click | Key {
	return e;
}

function put<T>(arr: T[], v: T): void {
	arr.push(v);
}

function weigh3(v: Click | Key | Wheel): int32 {
	return v.kind == K.Wheel ? 3 : v.kind == K.Key ? 2 : 1;
}

function main(): void {
	const key: Ev = make(-1);
	const click: Ev = make(4);
	const held: Click | Key = key;
	const list: (Click | Key)[] = [];
	put(list, click);
	const wheel: Ev3 = { kind: K.Wheel, dy: 9 };
	const many: (Click | Key | Wheel)[] = [];
	const keyOf3: Ev3 = { kind: K.Key, code: 2 };
	put(many, wheel);
	put(many, keyOf3);
	console.log(`${weigh(key)} ${weigh(back(click))} ${weigh(held)} ${weigh(list[0])}|${weigh3(many[0])} ${weigh3(many[1])}`);
}
main();
