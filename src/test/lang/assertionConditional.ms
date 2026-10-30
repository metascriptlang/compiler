type List<T> = T[];

let reads: int32 = 0;

function next(): boolean {
	reads += 1;
	return true;
}

test "an asserted boolean remains the condition" {
	const on: boolean = true;
	const off: boolean = false;
	assert (on as boolean ? 1 : 2) == 1;
	assert (off as boolean ? 1 : 2) == 2;
}

test "string assertions keep true and false arms" {
	const text: string = "ready";
	const empty: string = "";
	assert (text as string ? "text" : "empty") == "text";
	assert (empty as string ? "text" : "empty") == "empty";
}

test "generic array and nullable union assertions stop before the question" {
	const values: List<int32> = [1];
	const missing: List<int32> | null = null;
	assert (values as List<int32> ? values[0] : 0) == 1;
	assert (missing as (List<int32> | null) ? 1 : 0) == 0;
}

test "asserted conditions preserve enclosing conditional colons" {
	const on: boolean = true;
	const off: boolean = false;
	assert (on ? off as boolean ? 1 : 2 : 3) == 2;
	assert (off ? 1 : on as boolean ? -2 : 3) == -2;
}

test "an asserted condition is evaluated once" {
	reads = 0;
	assert (next() as boolean ? reads : 0) == 1;
	assert reads == 1;
}
