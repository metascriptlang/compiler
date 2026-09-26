// @stdout: -1294967296 0 -1294967295 1294967295 1705032704 -647483648 | 5 5 4 -6 10 2 | 2 2 3 -3 4 1 | 2 2 3 -3 4 1 | -1 255 -2 0 -2 -1 | 2147483647 255 2147483646 -2147483648 -2 1073741823 | 0 0 1 -1 0 0 | 0 0 1 -1 0 0 | 0 0 1 -1 0 0 | -1294967289 2
// @xfail(raiser): Raiser range-checks a number operand of a bitwise operator and raises past int32, and cannot evaluate the builtin NaN (same on the baseline)
// note: a number operand of a bitwise operator wraps by ECMAScript ToInt32 on every backend and build mode: NaN and the infinities give 0, the rest is truncated and reduced modulo 2^32 (number-toint32: C range-checked the operand and raised past int32, and converted it with undefined behaviour under --danger).

function row(v: number): string {
	return `${v | 0} ${v & 0xff} ${v ^ 1} ${~v} ${v << 1} ${v >> 1}`;
}

const vals: number[] = [3000000000, 4294967301, 9007199254740994, 2.7, -1.5, -2147483649, NaN, Infinity, -Infinity];
const rows: string[] = [];
for (const v of vals) rows.push(row(v));
const i: int32 = 7;
rows.push(`${vals[0] | i} ${i ^ vals[1]}`);
console.log(rows.join(" | "));
