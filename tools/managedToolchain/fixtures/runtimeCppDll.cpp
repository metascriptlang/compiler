#include <stdexcept>
#include <vector>
#include <windows.h>

extern "C" __declspec(dllexport) int cppSum(int count) {
    std::vector<int> values(count, 2);
    try {
        if (count < 0) throw std::out_of_range("count");
        int total = 0;
        for (int value : values) total += value;
        return total;
    } catch (const std::exception &) {
        return -1;
    }
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved) {
    (void)instance; (void)reason; (void)reserved;
    return TRUE;
}
