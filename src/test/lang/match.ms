// Language tests: match expressions

// --- Shared enums ---

enum Color { Red, Green, Blue }
enum Suit { Hearts, Diamonds, Clubs, Spades }
enum Op { Add, Sub, Mul, Div }
enum Season { Spring, Summer, Autumn, Winter }

// --- Shared helper functions ---

function colorName(c: Color): string {
	return match (c) {
		Color.Red => "red",
		Color.Green => "green",
		Color.Blue => "blue",
		_ => "unknown",
	};
}

function suitColor(s: Suit): string {
	return match (s) {
		Suit.Hearts | Suit.Diamonds => "red",
		Suit.Clubs | Suit.Spades => "black",
	};
}

function calc(op: Op, a: number, b: number): number {
	return match (op) {
		Op.Add => a + b,
		Op.Sub => a - b,
		Op.Mul => a * b,
		Op.Div => a / b,
	};
}

function seasonTemp(s: Season): string {
	return match (s) {
		Season.Spring => "mild",
		Season.Summer => "hot",
		Season.Autumn => "cool",
		Season.Winter => "cold",
	};
}

function seasonActivity(s: Season): string {
	const temp = seasonTemp(s);
	return match (s) {
		Season.Spring => "garden (" + temp + ")",
		Season.Summer => "swim (" + temp + ")",
		Season.Autumn => "hike (" + temp + ")",
		Season.Winter => "ski (" + temp + ")",
	};
}

function classify(n: number): string {
	return match (n) {
		0 => "zero",
		1 => "one",
		2 | 3 | 5 | 7 => "small prime",
		_ => "other",
	};
}

function httpStatus(code: number): string {
	return match (code) {
		200 => "OK",
		201 => "Created",
		301 => "Moved",
		400 => "Bad Request",
		404 => "Not Found",
		500 => "Server Error",
		_ => "Unknown",
	};
}

function greet(lang: string): string {
	return match (lang) {
		"en" => "hello",
		"es" => "hola",
		"fr" => "bonjour",
		_ => "hi",
	};
}

function isVowel(ch: string): boolean {
	return match (ch) {
		"a" | "e" | "i" | "o" | "u" => true,
		"A" | "E" | "I" | "O" | "U" => true,
		_ => false,
	};
}

function describe(n: number): string {
	return match (n) {
		0 => "nothing",
		1 => {
			let s = "single";
			return s + " item";
		},
		2 => {
			let a = "tw";
			let b = "o items";
			return a + b;
		},
		_ => "many",
	};
}

function isWeekend(day: string): boolean {
	return match (day) {
		"sat" | "sun" => true,
		_ => false,
	};
}

// --- Tests ---

test "enum match returns correct variant name" {
	assert colorName(Color.Red) === "red";
	assert colorName(Color.Green) === "green";
	assert colorName(Color.Blue) === "blue";
}

test "enum alternatives with pipe" {
	assert suitColor(Suit.Hearts) === "red";
	assert suitColor(Suit.Diamonds) === "red";
	assert suitColor(Suit.Clubs) === "black";
	assert suitColor(Suit.Spades) === "black";
}

test "enum match with arithmetic" {
	assert calc(Op.Add, 10, 3) === 13;
	assert calc(Op.Sub, 10, 3) === 7;
	assert calc(Op.Mul, 10, 3) === 30;
}

test "number match with alternatives and wildcard" {
	assert classify(0) === "zero";
	assert classify(1) === "one";
	assert classify(3) === "small prime";
	assert classify(7) === "small prime";
	assert classify(4) === "other";
}

test "number match for HTTP status codes" {
	assert httpStatus(200) === "OK";
	assert httpStatus(404) === "Not Found";
	assert httpStatus(500) === "Server Error";
	assert httpStatus(999) === "Unknown";
}

test "string match" {
	assert greet("en") === "hello";
	assert greet("es") === "hola";
	assert greet("fr") === "bonjour";
	assert greet("de") === "hi";
}

test "string match with alternatives" {
	assert isVowel("a");
	assert isVowel("E");
	assert !isVowel("b");
	assert !isVowel("z");
}

test "string alternatives for weekend check" {
	assert isWeekend("sat") === true;
	assert isWeekend("sun") === true;
	assert isWeekend("mon") === false;
}

test "block arms returning values" {
	assert describe(0) === "nothing";
	assert describe(1) === "single item";
	assert describe(2) === "two items";
	assert describe(99) === "many";
}

test "statement-form match with side effects" {
	let result = "";
	match (Color.Green) {
		Color.Red => { result = "r"; },
		Color.Green => { result = "g"; },
		Color.Blue => { result = "b"; },
		_ => { result = "?"; },
	};
	assert result === "g";
}

test "nested match via function composition" {
	assert seasonActivity(Season.Summer) === "swim (hot)";
	assert seasonActivity(Season.Winter) === "ski (cold)";
	assert seasonActivity(Season.Spring) === "garden (mild)";
}
