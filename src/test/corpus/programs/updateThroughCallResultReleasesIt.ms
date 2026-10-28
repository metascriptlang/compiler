// @stdout: 2 1 1 -1 2
class Inner { n: int32 = 0; }
class Box { n: int32 = 0; inner: Inner = new Inner(); }
const theBox = new Box();
let made: int32 = 0;
function getBox(): Box { return theBox; }
function mk(): Box {
	made = made + 1;
	return new Box();
}

function run(): void {
	getBox().n++;
	mk().n++;
	const old = getBox().n++;
	const pre = ++mk().n;
	getBox().inner.n--;
	console.log(`${theBox.n} ${old} ${pre} ${theBox.inner.n} ${made}`);
}
run();
