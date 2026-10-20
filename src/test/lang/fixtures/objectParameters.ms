export function okText(x: { ok: true; value: string }): string {
	return `${x.ok}:${x.value}`;
}

export type OkCount = { ok: true; value: int32 };

export function okCount(x: OkCount): int32 {
	return x.value;
}
