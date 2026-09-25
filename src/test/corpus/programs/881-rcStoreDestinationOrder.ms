interface Box { s: string; }

let counter: int32 = 0;
function nextIdx(): int32 {
	counter += 1;
	return counter - 1;
}

const boxes: Box[] = [{ s: "a" }, { s: "b" }, { s: "c" }];
let i: int32 = 0;
boxes[i++] = { s: "z" };
console.log("i=" + i + " " + boxes[0].s + boxes[1].s + boxes[2].s);

const strs: string[] = ["a", "b", "c", "d"];
let j: int32 = 0;
strs[j++] = "z";
strs[j++] = "y" + j;
const src = "q" + 1;
strs[j++] = src;
console.log("j=" + j + " " + strs.join(","));

const arr: string[] = ["a", "b", "c"];
arr[nextIdx()] += "x";
console.log("calls=" + counter + " " + arr.join(","));
const brr: string[] = ["a", "b", "c"];
brr[nextIdx()] = "z" + counter;
console.log("calls=" + counter + " " + brr.join(","));
