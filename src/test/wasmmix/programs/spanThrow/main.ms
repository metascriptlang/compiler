// @stdout: 100,200,300
// @stdout: threw stop
// @stdout: 100,200,3
// @stdout: 1
// @stdout: true,true,false
// @stdout: threw tick
// @stdout: true,false,false
// @stdout: threw half
// @stdout: 2,4.5,1
import { editThrough, stampThrough, halveThrough } from "./spanThrowWasm";

function attempt(run: () => void): string {
	try {
		run();
		return "returned";
	} catch (e) {
		return "threw " + e.message;
	}
}

let done: Vec<int32> = [1, 2, 3];
editThrough(done, (v: Span<int32>): void => {
	v[1] = 200;
});
console.log(done.join(","));

let cut: Vec<int32> = [1, 2, 3];
console.log(attempt((): void => {
	editThrough(cut, (v: Span<int32>): void => {
		v[1] = 200;
		throw new Error("stop");
	});
}));
console.log(cut.join(","));

let marks: Vec<boolean> = [false, false, false];
console.log(`${stampThrough(marks, (at: int32): void => {})}`);
console.log(marks.join(","));
let stopped: Vec<boolean> = [false, false, false];
console.log(attempt((): void => {
	stampThrough(stopped, (at: int32): void => {
		throw new Error("tick");
	});
}));
console.log(stopped.join(","));

let fs: Vec<float32> = [4, 8, 2];
console.log(attempt((): void => {
	halveThrough(fs, 1, (v: Span<float32>, at: int32): void => {
		v[at] = v[at] + 0.5;
		throw new Error("half");
	});
}));
console.log(fs.join(","));
