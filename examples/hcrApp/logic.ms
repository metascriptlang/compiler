let frames: int32 = 0;

export function tick(): int32 {
	frames += 1;
	return frames;
}

export function message(): string {
	return "hello from logic.ms, edit this line and save";
}
