function initialize(): int32 {
	console.log("hidden init");
	return 1;
}

export const dup: int32 = initialize();
