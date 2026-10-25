struct Holder__fixture {
	Type__fixture* t;
};
void Holder__fixtureDestroy(Holder__fixture* self) {
	msDecref((*self).t);
}
void emitModuleJob__fixturecompileOms_u0(void) {
	Holder__fixture* h = 0;
	msDecref(h);
}
