// Language tests: recursion — direct, mutual, accumulator, divide-and-conquer

function factorial(n: number): number {
	if (n <= 1) return 1;
	return n * factorial(n - 1);
}

function fib(n: number): number {
	if (n <= 0) return 0;
	if (n === 1) return 1;
	return fib(n - 1) + fib(n - 2);
}

function isEvenR(n: number): boolean {
	if (n === 0) return true;
	return isOddR(n - 1);
}

function isOddR(n: number): boolean {
	if (n === 0) return false;
	return isEvenR(n - 1);
}

function sumTo(n: number, acc: number): number {
	if (n <= 0) return acc;
	return sumTo(n - 1, acc + n);
}

function gcd(a: number, b: number): number {
	if (b === 0) return a;
	return gcd(b, a % b);
}

function power(base: number, exp: number): number {
	if (exp === 0) return 1;
	return base * power(base, exp - 1);
}

function reverseStr(s: string): string {
	if (s.length <= 1) return s;
	return reverseStr(s.slice(1, s.length)) + s.slice(0, 1);
}

function arraySum(arr: number[], idx: number): number {
	if (idx >= arr.length) return 0;
	return arr[idx] + arraySum(arr, idx + 1);
}

test "factorial" {
	assert factorial(0) === 1;
	assert factorial(1) === 1;
	assert factorial(5) === 120;
	assert factorial(10) === 3628800;
}

test "fibonacci" {
	assert fib(0) === 0;
	assert fib(1) === 1;
	assert fib(6) === 8;
	assert fib(10) === 55;
}

test "mutual recursion" {
	assert isEvenR(0);
	assert !isEvenR(1);
	assert isEvenR(4);
	assert !isEvenR(7);
	assert isOddR(3);
	assert !isOddR(6);
}

test "accumulator recursion" {
	assert sumTo(5, 0) === 15;
	assert sumTo(10, 0) === 55;
	assert sumTo(0, 0) === 0;
	assert sumTo(100, 0) === 5050;
}

test "GCD" {
	assert gcd(12, 8) === 4;
	assert gcd(100, 75) === 25;
	assert gcd(7, 13) === 1;
	assert gcd(0, 5) === 5;
}

test "power" {
	assert power(2, 0) === 1;
	assert power(2, 10) === 1024;
	assert power(3, 4) === 81;
	assert power(5, 3) === 125;
}

test "recursive string reverse" {
	assert reverseStr("") === "";
	assert reverseStr("a") === "a";
	assert reverseStr("abc") === "cba";
	assert reverseStr("hello") === "olleh";
}

test "recursive array sum" {
	assert arraySum([1, 2, 3, 4, 5], 0) === 15;
	assert arraySum([], 0) === 0;
	assert arraySum([100], 0) === 100;
}
