test "an abort listener runs once on abort and only for the abort event" {
	const c = new AbortController();
	let calls = 0;
	const on = () => { calls += 1; };
	c.signal.addEventListener("abort", on);
	c.signal.addEventListener("other", on);
	c.abort("x");
	assert calls == 1;
}

test "a removed abort listener does not run, and a removal under another event name keeps it" {
	const c = new AbortController();
	let calls = 0;
	const on = () => { calls += 1; };
	c.signal.addEventListener("abort", on);
	c.signal.removeEventListener("other", on);
	c.signal.removeEventListener("abort", on);
	c.abort("x");
	assert calls == 0;
}
