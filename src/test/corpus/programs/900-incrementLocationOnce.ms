// @stdout: 11 20 1|getBox 2|f 1.5 3|mk 1
// @xfail(raiser): the Raiser VM truncates a float64 `x++` to an integer (0.5++ gives 1)
let calls: int32 = 0;
function next(): int32 {
	calls = calls + 1;
	return calls - 1;
}
class Box { n: int32 = 0; f: float64 = 0.5; }
const theBox = new Box();
let boxCalls: int32 = 0;
function getBox(): Box {
	boxCalls = boxCalls + 1;
	return theBox;
}
let made: int32 = 0;
function mk(): Box {
	made = made + 1;
	return new Box();
}
function run(): void {
	const arr: int32[] = [10, 20, 30, 40];
	++arr[next()];
	const line = arr[0].toString() + " " + arr[1].toString() + " " + calls.toString();
	const big: int64[] = [1, 2, 3];
	big[next()]--;
	getBox().n++;
	getBox().f++;
	--getBox().n;
	mk().n++;
	console.log(line + "|getBox " + (boxCalls - 1).toString() + "|f " + theBox.f.toString() + " " + boxCalls.toString() + "|mk " + made.toString());
	console.log(big[0], big[1], big[2], calls, theBox.n);
}
run();
