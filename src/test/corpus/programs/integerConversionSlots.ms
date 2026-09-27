// @stdout: conversion 12 3 12 -12 -3 -12

function twice(value: number): number { return value * 2.0; }
function returned(value: int64): number { return value; }
function converted(value: int64): number {
	const declared: number = value;
	return declared + returned(value) + twice(value);
}
function narrow(value: int32): number {
	const declared: number = value;
	return declared;
}
function widened(value: int32): int64 { return value as int64; }
console.log(`conversion ${converted(3)} ${narrow(3)} ${converted(widened(3))} ${converted(-3)} ${narrow(-3)} ${converted(widened(-3))}`);
