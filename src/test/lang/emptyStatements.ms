test "an empty loop body leaves the following block outside the loop" {
	;
	let count = 0;
	while (count++ < 2);
	{
		count += 10;
	}
	assert count == 13;
}

test "empty for do and else bodies keep their control flow" {
	let updates = 0;
	for (updates = 0; updates < 3; updates += 1);
	let count = 0;
	do; while (++count < 2);
	if (false) updates = 99; else;
	assert updates == 3;
	assert count == 2;
}

test "do accepts a nonempty unbraced body" {
	let visits = 0;
	do visits += 1; while (visits < 2);
	assert visits == 2;
}
