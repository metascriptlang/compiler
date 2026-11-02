// @stdout: 100,200,300
// @stdout: threw stop
// @stdout: 100,200,3
// @stdout: 1
// @stdout: true,true,false
// @stdout: threw tick
// @stdout: true,false,false
// @stdout: threw half
// @stdout: 2,4,1
// @stdout: 6
// @stdout: threw read
// @stdout: 1,2,3
import { editThenStop, stampThenTick, halveThenStop, sumThenStop } from "./spanThrowWasm";

function attempt(run: () => void): string {
	try {
		run();
		return "returned";
	} catch (e) {
		return "threw " + e.message;
	}
}

let done: Vec<int32> = [1, 2, 3];
editThenStop(done, -1);
console.log(done.join(","));

let cut: Vec<int32> = [1, 2, 3];
console.log(attempt((): void => {
	editThenStop(cut, 0);
}));
console.log(cut.join(","));

let marks: Vec<boolean> = [false, false, false];
console.log(`${stampThenTick(marks, false)}`);
console.log(marks.join(","));
let stopped: Vec<boolean> = [false, false, false];
console.log(attempt((): void => {
	stampThenTick(stopped, true);
}));
console.log(stopped.join(","));

let fs: Vec<float32> = [4, 8, 2];
console.log(attempt((): void => {
	halveThenStop(fs);
}));
console.log(fs.join(","));

let seen: Vec<int32> = [1, 2, 3];
console.log(`${sumThenStop(seen, false)}`);
console.log(attempt((): void => {
	sumThenStop(seen, true);
}));
console.log(seen.join(","));
