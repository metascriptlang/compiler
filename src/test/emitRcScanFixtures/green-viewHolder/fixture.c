struct View__fixture {
	Type__fixture* t;
	Builder__fixture* b;
};
struct HashSet_f1x__string {
	int32_t len;
};
void View__fixtureDestroy(View__fixture* self) {
	msDecref((*self).b);
}
void emitModuleJob__fixturecompileOms_u0(void) {
	View__fixture* v = 0;
	Builder__fixture* b = 0;
	HashSet_f1x__string* s = 0;
	msIncref(v);
	msDecref(v);
	msDecref(b);
	msDecref(s);
}
