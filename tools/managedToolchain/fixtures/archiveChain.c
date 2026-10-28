#if defined(MEMBER_A)
int fromB(void);
int fromA(void) { return 10 + fromB(); }
#elif defined(MEMBER_B1)
int fromB(void) { return 1; }
#elif defined(MEMBER_B2)
int fromB2(void) { return 2; }
#elif defined(MEMBER_UNUSED)
__attribute__((export_name("leak"))) int leak(void) { return 99; }
#else
int fromA(void);
int fromB2(void);
__attribute__((export_name("run"))) int run(void) { return fromA() + fromB2(); }
#endif
