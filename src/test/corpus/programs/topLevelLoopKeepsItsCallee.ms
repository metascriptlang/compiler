// @stdout: do-while 5
// @stdout: switch 7

function limit(): int32 { return 5; }
function seven(): int32 { return 7; }

let n = 0;
do { n += 1; } while (n < limit());
console.log(`do-while ${n}`);

const k: int32 = 1;
switch (k) {
	case 1: console.log(`switch ${seven()}`); break;
	default: console.log("switch other");
}
