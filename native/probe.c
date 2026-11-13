#include <windows.h>
#include <stdio.h>
/* The project folder, with a trailing slash. native/build.sh passes it as -DPVE_ROOT="\"<folder>/\"". */
#ifndef PVE_ROOT
#define PVE_ROOT "C:/MaraudersPvE/"
#endif
BOOL WINAPI DllMain(HINSTANCE h, DWORD why, LPVOID r) {
    if (why == DLL_PROCESS_ATTACH) {
        FILE *f = fopen(PVE_ROOT "bridge/native_probe.txt", "w");
        if (f) { fprintf(f, "loaded in pid %lu, exe base %p\n", GetCurrentProcessId(), (void*)GetModuleHandleA(NULL)); fclose(f); }
    }
    return TRUE;
}
