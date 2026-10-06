export function sizeCode<T>(): int32 {
	const size = @comptime { return sizeof(T); };
	return size;
}
