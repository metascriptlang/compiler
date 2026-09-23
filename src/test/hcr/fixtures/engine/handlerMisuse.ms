@beforeReload
function withParameter(count: int32): void {
	console.log(count);
}

@afterReload
function withResult(): int32 {
	return 1;
}

@exportName("named")
@beforeReload
function doublyNamed(): void {}

withParameter(1);
withResult();
doublyNamed();
