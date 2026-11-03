// @stdout: 7 7 7 7 7 | 2,4,6

type Brand<T> = T;
type Twice<T> = Brand<Brand<T>>;

function sumLocal(n: number): number {
	const zs: Brand<number[]> = [1, 2, 3];
	let t: number = 0;
	let i = 0;
	while (i < zs.length) {
		t += zs[i];
		i += 1;
	}
	return t + n;
}

function sumNestedAlias(n: number): number {
	const zs: Twice<number[]> = [1, 2, 3];
	let t: number = 0;
	let i = 0;
	while (i < zs.length) {
		t += zs[i];
		i += 1;
	}
	return t + n;
}

function sumParam(zs: Brand<number[]>, n: number): number {
	let t: number = 0;
	let i = 0;
	while (i < zs.length) {
		t += zs[i];
		i += 1;
	}
	return t + n;
}

function sumPlainLocal(n: number): number {
	const zs: number[] = [1, 2, 3];
	let t: number = 0;
	let i = 0;
	while (i < zs.length) {
		t += zs[i];
		i += 1;
	}
	return t + n;
}

function sumRefParam(ref zs: Brand<number[]>, n: number): number {
	let t: number = 0;
	let i = 0;
	while (i < zs.length) {
		t += zs[i];
		i += 1;
	}
	return t + n;
}

function doubleLocal(): string {
	const zs: Brand<number[]> = [1, 2, 3];
	let i = 0;
	while (i < zs.length) {
		zs[i] = zs[i] * 2;
		i += 1;
	}
	return zs.join(",");
}

let held: Brand<number[]> = [1, 2, 3];
console.log(`${sumLocal(1)} ${sumNestedAlias(1)} ${sumParam([1, 2, 3], 1)} ${sumPlainLocal(1)} ${sumRefParam(held, 1)} | ${doubleLocal()}`);
