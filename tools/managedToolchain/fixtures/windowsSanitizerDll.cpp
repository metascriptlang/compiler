#include <windows.h>

struct Base {
    virtual ~Base() {}
    virtual int value() const { return 1; }
};

struct Derived : Base {
    int value() const override { return 2; }
};

/* step 0 calls a Derived as a Derived and returns 2; step 1 calls a Base object as a Derived, which UBSan's vptr check
   reports. */
extern "C" __declspec(dllexport) int sanitizerCppProbe(int step) {
    Base *object = step == 1 ? new Base : new Derived;
    int result = static_cast<Derived *>(object)->value();
    delete object;
    return result;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved) {
    (void)instance; (void)reason; (void)reserved;
    return TRUE;
}
