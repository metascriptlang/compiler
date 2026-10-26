function fib(n: int32): int32 {
	if (n < 2) return n;
	return fib(n - 1) + fib(n - 2);
}

console.log(`fib ${fib(38)}`);
