/*
 * pvestacks.dll: diagnostic for a hung game process. Inject into the running process (tracelaunch.exe -p <pid> ...);
 * on load it suspends every other thread in turn, unwinds its stack (x64 unwind data via RtlVirtualUnwind; where a
 * module has none, e.g. Denuvo-protected exe code, it falls back to scanning the stack for return-address-looking
 * values), and writes everything to capture/stacks-<pid>.log as module+offset. Then it is done; it changes nothing.
 */
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>

/* The project folder, with a trailing slash. native/build.sh passes it as -DPVE_ROOT="\"<folder>/\"". */
#ifndef PVE_ROOT
#define PVE_ROOT "C:/MaraudersPvE/"
#endif
#define DIR PVE_ROOT "capture/"
static FILE *out;

static int where(DWORD64 p, char *o, int n) {
    HMODULE m = NULL; char path[MAX_PATH];
    if (!GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCSTR)p, &m) || !m) {
        snprintf(o, n, "%llx", (unsigned long long)p); return 0;
    }
    GetModuleFileNameA(m, path, MAX_PATH); char *s = strrchr(path, '\\');
    snprintf(o, n, "%s+%llx", s ? s + 1 : path, (unsigned long long)(p - (DWORD64)m)); return 1;
}

static void walk(HANDLE th, DWORD tid) {
    CONTEXT c = {0}; c.ContextFlags = CONTEXT_FULL;
    if (!GetThreadContext(th, &c)) { fprintf(out, "thread %lu: GetThreadContext failed %lu\n", tid, GetLastError()); return; }
    fprintf(out, "thread %lu  rip/rsp %llx/%llx\n", tid, (unsigned long long)c.Rip, (unsigned long long)c.Rsp);
    DWORD64 scanFrom = c.Rsp;
    for (int i = 0; i < 40 && c.Rip; i++) {
        char w[300]; where(c.Rip, w, sizeof w);
        /* Nonvolatile registers as restored for this frame: a lock pointer a function was holding in rbx/rsi shows here. */
        fprintf(out, "   %2d %-48s rbx=%llx rsi=%llx rdi=%llx rbp=%llx r12=%llx r13=%llx r14=%llx r15=%llx\n", i, w,
                (unsigned long long)c.Rbx, (unsigned long long)c.Rsi, (unsigned long long)c.Rdi, (unsigned long long)c.Rbp,
                (unsigned long long)c.R12, (unsigned long long)c.R13, (unsigned long long)c.R14, (unsigned long long)c.R15);
        DWORD64 base = 0; PRUNTIME_FUNCTION f = RtlLookupFunctionEntry(c.Rip, &base, NULL);
        if (!f) { scanFrom = c.Rsp; fprintf(out, "      (no unwind data; scanning stack)\n"); goto scan; }
        void *hd = NULL; DWORD64 est = 0;
        RtlVirtualUnwind(UNW_FLAG_NHANDLER, base, c.Rip, f, &c, &hd, &est, NULL);
    }
    return;
scan:
    for (int k = 0, shown = 0; k < 2048 && shown < 40; k++) {
        DWORD64 v = 0; SIZE_T got = 0;
        if (!ReadProcessMemory(GetCurrentProcess(), (void *)(scanFrom + k * 8), &v, 8, &got) || got != 8) break;
        MEMORY_BASIC_INFORMATION mi;
        if (v < 0x10000 || !VirtualQuery((void *)v, &mi, sizeof mi)) continue;
        if (!(mi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))) continue;
        char w[300]; if (!where(v, w, sizeof w)) continue;
        fprintf(out, "      ?  [rsp+%x] %s\n", k * 8, w); shown++;
    }
}

static DWORD WINAPI run(LPVOID p) {
    (void)p;
    char path[MAX_PATH]; snprintf(path, sizeof path, DIR "stacks-%lu.log", GetCurrentProcessId());
    out = fopen(path, "w"); if (!out) return 0;
    DWORD me = GetCurrentThreadId(), pid = GetCurrentProcessId();
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    THREADENTRY32 te = {sizeof te};
    for (BOOL ok = Thread32First(snap, &te); ok; ok = Thread32Next(snap, &te)) {
        if (te.th32OwnerProcessID != pid || te.th32ThreadID == me) continue;
        HANDLE th = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, te.th32ThreadID);
        if (!th) continue;
        if (SuspendThread(th) != (DWORD)-1) { walk(th, te.th32ThreadID); ResumeThread(th); }
        CloseHandle(th); fflush(out);
    }
    CloseHandle(snap);
    fprintf(out, "done\n"); fclose(out);
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD why, LPVOID r) {
    (void)h; (void)r;
    if (why == DLL_PROCESS_ATTACH) CreateThread(NULL, 0, run, NULL, 0, NULL);
    return TRUE;
}
