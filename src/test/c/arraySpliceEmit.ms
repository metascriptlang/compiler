// E2E: three-argument splice emit family — the element type picks the C
// runtime helper. Value elements (number/string/boolean-uint8) go through
// their typed Splice3 helpers; a ref element keeps msRefArraySplice3 (void*).

import { compileToC } from "../helpers";

test "E2E C: splice insert on number[] calls msNumberArraySplice3" {
	const c = compileToC(`
		function main(): void {
			const xs: number[] = [1, 2, 3];
			xs.splice(0, 0, 9);
			console.log(xs[0].toString());
		}
	`);
	assert c.ok;
	assert c.value.contains("msNumberArraySplice3("), c.value.slice(c.value.indexOf("Splice3") - 40, c.value.indexOf("Splice3") + 40);
	assert !c.value.contains("msRefArraySplice3(");
}

test "E2E C: splice insert on string[] calls msStringArraySplice3" {
	const c = compileToC(`
		function main(): void {
			const ss: string[] = ["a", "b"];
			ss.splice(0, 0, "z");
			console.log(ss[0]);
		}
	`);
	assert c.ok;
	assert c.value.contains("msStringArraySplice3(");
	assert !c.value.contains("msRefArraySplice3(");
}

test "E2E C: splice insert on boolean[] calls msUint8ArraySplice3" {
	const c = compileToC(`
		function main(): void {
			const bs: boolean[] = [true, false];
			bs.splice(0, 1, false);
			console.log(bs[0].toString());
		}
	`);
	assert c.ok;
	assert c.value.contains("msUint8ArraySplice3(");
	assert !c.value.contains("msRefArraySplice3(");
}

test "E2E C: splice insert on a ref array keeps msRefArraySplice3" {
	const c = compileToC(`
		interface Box { id: number }
		function main(): void {
			const box: Box = { id: 9 };
			const bs: Box[] = [{ id: 1 }];
			bs.splice(0, 0, box);
			console.log(bs[0].id.toString());
		}
	`);
	assert c.ok;
	assert c.value.contains("msRefArraySplice3(");
}
