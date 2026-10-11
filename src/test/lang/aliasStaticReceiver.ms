struct Counter { n: int32; }
function start(this typeof Counter, n: int32): Counter { return { n }; }
function value(this c: Counter): int32 { return c.n; }
type Gauge = Counter;
type GaugeTwice = Gauge;

test "a static extension is callable through a transparent alias receiver" {
	assert Gauge.start(5).value() == 5;
}

test "a static extension is callable through a nested alias receiver" {
	const c = GaugeTwice.start(6);
	assert c.value() == 6;
	assert Counter.start(7).value() == 7;
}

function reset(this typeof Gauge): Counter { return { n: 0 }; }

test "an extension declared on the alias name is callable through the struct name" {
	assert Counter.reset().value() == 0;
	assert GaugeTwice.reset().value() == 0;
}
