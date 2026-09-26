let $hits: int32 = 0;

export function hit(): int32 {
	$hits += 1;
	return $hits;
}
