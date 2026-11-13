/* tracelaunch.exe <dll[;dll2;...]> <exe> [args...]: starts exe suspended, loads each dll into it (in order), resumes. */
#include <windows.h>
#include <stdio.h>

static int inject(HANDLE proc, const wchar_t *dll) {
    size_t n = (wcslen(dll) + 1) * 2;
    void *mem = VirtualAllocEx(proc, NULL, n, MEM_COMMIT, PAGE_READWRITE);
    if (!mem) return 0;
    WriteProcessMemory(proc, mem, dll, n, NULL);
    HANDLE t = CreateRemoteThread(proc, NULL, 0, (LPTHREAD_START_ROUTINE)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "LoadLibraryW"), mem, 0, NULL);
    if (!t) return 0;
    WaitForSingleObject(t, 15000);
    DWORD mod = 0; GetExitCodeThread(t, &mod);
    wprintf(L"  injected %ls (base low32 %08lx)\n", dll, mod);
    CloseHandle(t);
    return 1;
}

int wmain(int argc, wchar_t **argv) {
    /* tracelaunch -p <pid> <dll>: load a dll into an already running process (e.g. pvestacks.dll into a hung one). */
    if (argc == 4 && !wcscmp(argv[1], L"-p")) {
        HANDLE p = OpenProcess(PROCESS_ALL_ACCESS, FALSE, (DWORD)_wtoi(argv[2]));
        if (!p) { fwprintf(stderr, L"OpenProcess %lu\n", GetLastError()); return 1; }
        return inject(p, argv[3]) ? 0 : 1;
    }
    if (argc < 3) { fwprintf(stderr, L"usage: tracelaunch <dll[;dll2;...]> <exe> [args] | tracelaunch -p <pid> <dll>\n"); return 2; }
    wchar_t cmd[4096]; swprintf(cmd, 4096, L"\"%ls\"", argv[2]);
    for (int i = 3; i < argc; i++) { wcscat(cmd, L" "); wcscat(cmd, argv[i]); }
    wchar_t dir[MAX_PATH]; wcscpy(dir, argv[2]); wchar_t *s = wcsrchr(dir, L'\\'); if (s) *s = 0;
    STARTUPINFOW si = {sizeof si}; PROCESS_INFORMATION pi;
    if (!CreateProcessW(argv[2], cmd, NULL, NULL, FALSE, CREATE_SUSPENDED, NULL, dir, &si, &pi)) { fwprintf(stderr, L"CreateProcess %lu\n", GetLastError()); return 1; }
    wprintf(L"pid %lu\n", pi.dwProcessId);
    wchar_t list[2048]; wcsncpy(list, argv[1], 2047); list[2047] = 0;
    for (wchar_t *ctx = NULL, *d = wcstok(list, L";", &ctx); d; d = wcstok(NULL, L";", &ctx)) {
        if (!inject(pi.hProcess, d)) { fwprintf(stderr, L"inject %ls failed %lu\n", d, GetLastError()); TerminateProcess(pi.hProcess, 1); return 1; }
    }
    ResumeThread(pi.hThread);
    return 0;
}
