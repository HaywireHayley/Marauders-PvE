/*
 * pvetrace.dll: diagnostic for "a second copy of the game quits on the same PC".
 * Patches the IMPORT TABLES of the game's own modules (exe + DLLs under \PHtest\, re-scanned each second) so a
 * handful of kernel32/user32 calls are logged with their result, last error and caller to capture/trace-<pid>.log.
 * It never touches ntdll (the game's Denuvo anti-tamper kills the process if ntdll's syscall stubs are patched),
 * only IAT slots, the same technique pvenet.dll uses. Watched calls: the ones a single-instance guard uses
 * (CreateMutex/OpenMutex, CreateEvent/OpenEvent, CreateFileMapping/OpenFileMapping, FindWindow, snapshots) and
 * the exits (ExitProcess, PostQuitMessage). Loaded by tracelaunch.exe before the process resumes.
 */
#include <windows.h>
#include <psapi.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdarg.h>

/* The project folder, with a trailing slash. native/build.sh passes it as -DPVE_ROOT="\"<folder>/\"". */
#ifndef PVE_ROOT
#define PVE_ROOT "C:/MaraudersPvE/"
#endif
#define DIR PVE_ROOT "capture/"

static HANDLE logf;
static DWORD tls;
static HMODULE self;

static void lg(const char *fmt, ...) {
    char b[3000]; va_list a; va_start(a, fmt);
    int n = vsnprintf(b, sizeof b - 2, fmt, a); va_end(a);
    if (n < 0) return;
    if (n > (int)sizeof b - 2) n = (int)sizeof b - 2;
    b[n++] = '\n'; DWORD w; WriteFile(logf, b, (DWORD)n, &w, NULL);
}
static void where(void *p, char *out, int n) {
    HMODULE m = NULL; char path[MAX_PATH] = "?";
    if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, p, &m) && m) {
        GetModuleFileNameA(m, path, MAX_PATH);
        char *s = strrchr(path, '\\'); snprintf(out, n, "%s+%llx", s ? s + 1 : path, (unsigned long long)((char *)p - (char *)m));
    } else snprintf(out, n, "%p", p);
}
static void backtrace(char *out, int n, int skip, int depth) {
    void *fr[64]; USHORT c = RtlCaptureStackBackTrace((DWORD)skip, (DWORD)depth, fr, NULL);
    out[0] = 0; int used = 0;
    for (USHORT i = 0; i < c && used < n - 80; i++) { char w[200]; where(fr[i], w, sizeof w); used += snprintf(out + used, n - used, "%s%s", i ? " < " : "", w); }
}
static int enter(void) { if (TlsGetValue(tls)) return 0; TlsSetValue(tls, (void *)1); return 1; }
static void leave(void) { TlsSetValue(tls, NULL); }
static void nm(const void *p, int wide, char *out, int n) {
    if (!p) { snprintf(out, n, "(null)"); return; }
    if ((ULONG_PTR)p < 0x10000) { snprintf(out, n, "#%llu", (unsigned long long)(ULONG_PTR)p); return; }
    if (wide) { int k = WideCharToMultiByte(CP_UTF8, 0, p, -1, out, n - 1, NULL, NULL); out[k > 0 ? k - 1 : 0] = 0; }
    else { snprintf(out, n, "%s", (const char *)p); }
}

/* ---- wrappers ----------------------------------------------------------------------------------------- */
static int firstInstance;   /* PVE_FIRST_INSTANCE: make the second copy believe it is the first */
static HANDLE (WINAPI *rCreateMutexW)(LPSECURITY_ATTRIBUTES, BOOL, LPCWSTR);
static HANDLE WINAPI hCreateMutexW(LPSECURITY_ATTRIBUTES a, BOOL o, LPCWSTR name) {
    HANDLE h = rCreateMutexW(a, o, name); DWORD e = GetLastError();
    /* The engine-wide "UnrealEngine4" single-instance mutex: a second copy sees ALREADY_EXISTS and marks itself
     * "not first instance", which the nakama duplicate-session blueprint later uses to quit. Report it as freshly
     * created so the copy believes it is the first instance. */
    int spoof = firstInstance && name && !wcscmp(name, L"UnrealEngine4") && e == ERROR_ALREADY_EXISTS;
    if (spoof) SetLastError(ERROR_SUCCESS);
    if (name && enter()) { char s[400], cl[1500]; nm(name, 1, s, sizeof s); backtrace(cl, sizeof cl, 1, 4); lg("CreateMutexW \"%s\" -> %p err=%lu%s%s [%s]", s, h, e, e == ERROR_ALREADY_EXISTS ? " ALREADY_EXISTS" : "", spoof ? " -> SPOOFED FIRST" : "", cl); leave(); }
    return h;
}
static HANDLE (WINAPI *rOpenMutexW)(DWORD, BOOL, LPCWSTR);
static HANDLE WINAPI hOpenMutexW(DWORD acc, BOOL inh, LPCWSTR name) {
    HANDLE h = rOpenMutexW(acc, inh, name); DWORD e = GetLastError();
    if (name && enter()) { char s[400], cl[1500]; nm(name, 1, s, sizeof s); backtrace(cl, sizeof cl, 1, 4); lg("OpenMutexW \"%s\" -> %p err=%lu [%s]", s, h, e, cl); leave(); }
    return h;
}
static HANDLE (WINAPI *rCreateEventW)(LPSECURITY_ATTRIBUTES, BOOL, BOOL, LPCWSTR);
static HANDLE WINAPI hCreateEventW(LPSECURITY_ATTRIBUTES a, BOOL m, BOOL st, LPCWSTR name) {
    HANDLE h = rCreateEventW(a, m, st, name); DWORD e = GetLastError();
    if (name && enter()) { char s[400], cl[1500]; nm(name, 1, s, sizeof s); backtrace(cl, sizeof cl, 1, 4); lg("CreateEventW \"%s\" -> %p err=%lu%s [%s]", s, h, e, e == ERROR_ALREADY_EXISTS ? " ALREADY_EXISTS" : "", cl); leave(); }
    return h;
}
static HANDLE (WINAPI *rOpenEventW)(DWORD, BOOL, LPCWSTR);
static HANDLE WINAPI hOpenEventW(DWORD acc, BOOL inh, LPCWSTR name) {
    HANDLE h = rOpenEventW(acc, inh, name); DWORD e = GetLastError();
    if (name && enter()) { char s[400], cl[1500]; nm(name, 1, s, sizeof s); backtrace(cl, sizeof cl, 1, 4); lg("OpenEventW \"%s\" -> %p err=%lu [%s]", s, h, e, cl); leave(); }
    return h;
}
static HANDLE (WINAPI *rCreateFileMappingW)(HANDLE, LPSECURITY_ATTRIBUTES, DWORD, DWORD, DWORD, LPCWSTR);
static HANDLE WINAPI hCreateFileMappingW(HANDLE f, LPSECURITY_ATTRIBUTES a, DWORD prot, DWORD hi, DWORD lo, LPCWSTR name) {
    HANDLE h = rCreateFileMappingW(f, a, prot, hi, lo, name); DWORD e = GetLastError();
    if (name && enter()) { char s[400], cl[1500]; nm(name, 1, s, sizeof s); backtrace(cl, sizeof cl, 1, 4); lg("CreateFileMappingW \"%s\" -> %p err=%lu%s [%s]", s, h, e, e == ERROR_ALREADY_EXISTS ? " ALREADY_EXISTS" : "", cl); leave(); }
    return h;
}
static HANDLE (WINAPI *rOpenFileMappingW)(DWORD, BOOL, LPCWSTR);
static HANDLE WINAPI hOpenFileMappingW(DWORD acc, BOOL inh, LPCWSTR name) {
    HANDLE h = rOpenFileMappingW(acc, inh, name); DWORD e = GetLastError();
    if (name && enter()) { char s[400], cl[1500]; nm(name, 1, s, sizeof s); backtrace(cl, sizeof cl, 1, 4); lg("OpenFileMappingW \"%s\" -> %p err=%lu [%s]", s, h, e, cl); leave(); }
    return h;
}
static HWND (WINAPI *rFindWindowW)(LPCWSTR, LPCWSTR);
static HWND WINAPI hFindWindowW(LPCWSTR cls, LPCWSTR win) {
    HWND h = rFindWindowW(cls, win);
    if (enter()) { char a[300], b[300], cl[1500]; nm(cls, 1, a, sizeof a); nm(win, 1, b, sizeof b); backtrace(cl, sizeof cl, 1, 4); lg("FindWindowW class=\"%s\" win=\"%s\" -> %p [%s]", a, b, h, cl); leave(); }
    return h;
}
static HWND (WINAPI *rFindWindowExW)(HWND, HWND, LPCWSTR, LPCWSTR);
static HWND WINAPI hFindWindowExW(HWND p, HWND c, LPCWSTR cls, LPCWSTR win) {
    HWND h = rFindWindowExW(p, c, cls, win);
    if (enter()) { char a[300], b[300], cl[1500]; nm(cls, 1, a, sizeof a); nm(win, 1, b, sizeof b); backtrace(cl, sizeof cl, 1, 4); lg("FindWindowExW class=\"%s\" win=\"%s\" -> %p [%s]", a, b, h, cl); leave(); }
    return h;
}
/* Failed file opens only (sharing violations / access denied are what a "can I open my lock file" guard hits). */
static HANDLE (WINAPI *rCreateFileW)(LPCWSTR, DWORD, DWORD, LPSECURITY_ATTRIBUTES, DWORD, DWORD, HANDLE);
static HANDLE WINAPI hCreateFileW(LPCWSTR path, DWORD acc, DWORD share, LPSECURITY_ATTRIBUTES sa, DWORD disp, DWORD fl, HANDLE tmpl) {
    HANDLE h = rCreateFileW(path, acc, share, sa, disp, fl, tmpl); DWORD e = GetLastError();
    if (h == INVALID_HANDLE_VALUE && e != ERROR_FILE_NOT_FOUND && e != ERROR_PATH_NOT_FOUND && enter()) {
        char s[600], cl[1500]; nm(path, 1, s, sizeof s); backtrace(cl, sizeof cl, 1, 5);
        lg("CreateFileW FAILED \"%s\" access=%lx share=%lx disp=%lu err=%lu [%s]", s, acc, share, disp, e, cl); leave();
    }
    SetLastError(e);
    return h;
}
static HANDLE (WINAPI *rCreateToolhelp32Snapshot)(DWORD, DWORD);
static HANDLE WINAPI hCreateToolhelp32Snapshot(DWORD fl, DWORD pid) {
    HANDLE h = rCreateToolhelp32Snapshot(fl, pid);
    if (enter()) { char cl[1500]; backtrace(cl, sizeof cl, 1, 4); lg("CreateToolhelp32Snapshot flags=%lx -> %p [%s]", fl, h, cl); leave(); }
    return h;
}
/* A thread killed mid-allocation leaves the allocator lock owned by a dead thread (seen as a listen-server hang). */
static BOOL (WINAPI *rTerminateThread)(HANDLE, DWORD);
static BOOL WINAPI hTerminateThread(HANDLE th, DWORD code) {
    char cl[2500]; backtrace(cl, sizeof cl, 1, 24);
    lg("== TerminateThread(tid %lu, code %lu) from tid %lu  [%s]", GetThreadId(th), code, GetCurrentThreadId(), cl);
    return rTerminateThread(th, code);
}
static void (WINAPI *rExitProcess)(UINT);
static void WINAPI hExitProcess(UINT code) {
    char cl[2500]; backtrace(cl, sizeof cl, 1, 32);
    lg("== ExitProcess(%u) tid=%lu  [%s]", code, GetCurrentThreadId(), cl);
    rExitProcess(code);
}
/* Offset in the exe of the function that calls PostQuitMessage on the second-instance / nakama-disconnect quit
 * path (seen in capture/trace-*.log: "... < RaidGame-Win64-Shipping.exe+9fafd0 < PostQuitMessage"). When
 * PVE_SUPPRESS_QUIT is set, swallow a PostQuitMessage whose immediate caller is this site, so a co-op client is
 * not shut down by the duplicate-session logic; a genuine Alt-F4 / quit-button PostQuitMessage (different caller)
 * still goes through. 0 disables the match. */
static ULONG_PTR quitSite;      /* exe base + 0x9fafd0, resolved at init */
static int suppressQuit;

/* Writes live code bytes to the log as "DUMP rva=<hex> <hex bytes>" (rva relative to the exe base), for offline
 * disassembly (scripts/quitsite.py). Reads through ReadProcessMemory so an unreadable page fails instead of faulting. */
static void dump(ULONG_PTR addr, SIZE_T len) {
    BYTE buf[0x400]; SIZE_T got = 0;
    if (len > sizeof buf) len = sizeof buf;
    if (!ReadProcessMemory(GetCurrentProcess(), (void *)addr, buf, len, &got) || !got) { lg("DUMP rva=%llx unreadable", (unsigned long long)(addr - (ULONG_PTR)GetModuleHandleA(NULL))); return; }
    char hex[0x400 * 2 + 1]; for (SIZE_T i = 0; i < got; i++) sprintf(hex + i * 2, "%02x", buf[i]);
    lg("DUMP rva=%llx %s", (unsigned long long)(addr - (ULONG_PTR)GetModuleHandleA(NULL)), hex);
}
/* The quit routine, its caller, and the first bytes of every function either calls directly (E8 rel32). */
static void dumpQuitPath(void *caller, void *callers2) {
    ULONG_PTR sites[2] = {(ULONG_PTR)caller, (ULONG_PTR)callers2};
    for (int s = 0; s < 2; s++) {
        if (!sites[s]) continue;
        ULONG_PTR from = sites[s] - 0x200; dump(from, 0x240);
        BYTE b[0x240]; SIZE_T got = 0;
        if (!ReadProcessMemory(GetCurrentProcess(), (void *)from, b, sizeof b, &got)) continue;
        for (SIZE_T i = 0; i + 5 <= got; i++) if (b[i] == 0xE8) {
            LONG rel = *(LONG *)(b + i + 1); ULONG_PTR t = from + i + 5 + rel;
            if (t > (ULONG_PTR)GetModuleHandleA(NULL) && t < (ULONG_PTR)GetModuleHandleA(NULL) + 0x10000000) dump(t, 0x60);
        }
    }
}

static void (WINAPI *rPostQuitMessage)(int);
static void WINAPI hPostQuitMessage(int code) {
    void *fr[3]; USHORT c = RtlCaptureStackBackTrace(1, 3, fr, NULL);
    void *caller = c ? fr[0] : NULL;
    char cl[2000]; backtrace(cl, sizeof cl, 1, 20);
    if (caller == (void *)quitSite) dumpQuitPath(caller, c > 1 ? fr[1] : NULL);
    if (suppressQuit && caller == (void *)quitSite) {
        lg("== PostQuitMessage(%d) SUPPRESSED (quit-site caller) tid=%lu  [%s]", code, GetCurrentThreadId(), cl);
        return;
    }
    lg("== PostQuitMessage(%d) tid=%lu caller=%p  [%s]", code, GetCurrentThreadId(), caller, cl);
    rPostQuitMessage(code);
}

/* ---- IAT patching (per module; match by name, kernel32/user32 only) ---------------------------------- */
typedef struct { const char *name; void *hook; void **real; } Hook;
static Hook HOOKS[] = {
    { "CreateMutexW", hCreateMutexW, (void **)&rCreateMutexW },
    { "OpenMutexW", hOpenMutexW, (void **)&rOpenMutexW },
    { "CreateEventW", hCreateEventW, (void **)&rCreateEventW },
    { "OpenEventW", hOpenEventW, (void **)&rOpenEventW },
    { "CreateFileMappingW", hCreateFileMappingW, (void **)&rCreateFileMappingW },
    { "OpenFileMappingW", hOpenFileMappingW, (void **)&rOpenFileMappingW },
    { "FindWindowW", hFindWindowW, (void **)&rFindWindowW },
    { "FindWindowExW", hFindWindowExW, (void **)&rFindWindowExW },
    { "CreateToolhelp32Snapshot", hCreateToolhelp32Snapshot, (void **)&rCreateToolhelp32Snapshot },
    { "CreateFileW", hCreateFileW, (void **)&rCreateFileW },
    { "TerminateThread", hTerminateThread, (void **)&rTerminateThread },
    { "ExitProcess", hExitProcess, (void **)&rExitProcess },
    { "PostQuitMessage", (void *)hPostQuitMessage, (void **)&rPostQuitMessage },
};
#define NHOOKS (int)(sizeof HOOKS / sizeof HOOKS[0])

static int patchModule(HMODULE m) {
    unsigned char *b = (unsigned char *)m;
    IMAGE_DOS_HEADER *dos = (IMAGE_DOS_HEADER *)b;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return 0;
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(b + dos->e_lfanew);
    IMAGE_DATA_DIRECTORY dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (!dir.VirtualAddress) return 0;
    int n = 0;
    for (IMAGE_IMPORT_DESCRIPTOR *d = (IMAGE_IMPORT_DESCRIPTOR *)(b + dir.VirtualAddress); d->Name; d++) {
        const char *dll = (char *)(b + d->Name);
        if (_strnicmp(dll, "kernel32", 8) && _strnicmp(dll, "user32", 6) && _strnicmp(dll, "KernelBase", 10) && _strnicmp(dll, "api-ms-win", 10)) continue;
        if (!d->OriginalFirstThunk) continue;
        IMAGE_THUNK_DATA *names = (IMAGE_THUNK_DATA *)(b + d->OriginalFirstThunk);
        IMAGE_THUNK_DATA *iat = (IMAGE_THUNK_DATA *)(b + d->FirstThunk);
        for (; names->u1.AddressOfData; names++, iat++) {
            if (names->u1.Ordinal & IMAGE_ORDINAL_FLAG) continue;
            const char *fn = (char *)((IMAGE_IMPORT_BY_NAME *)(b + names->u1.AddressOfData))->Name;
            for (int i = 0; i < NHOOKS; i++) if (*HOOKS[i].real && !strcmp(fn, HOOKS[i].name) && (void *)iat->u1.Function != HOOKS[i].hook) {
                DWORD prot; VirtualProtect(&iat->u1.Function, sizeof(void *), PAGE_READWRITE, &prot);
                iat->u1.Function = (ULONG_PTR)HOOKS[i].hook;
                VirtualProtect(&iat->u1.Function, sizeof(void *), prot, &prot);
                n++;
            }
        }
    }
    return n;
}

static DWORD WINAPI start(LPVOID p) {
    (void)p;
    HMODULE k = GetModuleHandleA("kernel32.dll"), u = LoadLibraryA("user32.dll");
    for (int i = 0; i < NHOOKS; i++) {
        *HOOKS[i].real = (void *)GetProcAddress(k, HOOKS[i].name);
        if (!*HOOKS[i].real && u) *HOOKS[i].real = (void *)GetProcAddress(u, HOOKS[i].name);
    }
    lg("resolved originals; scanning modules");
    for (int round = 0; ; round++) {
        HMODULE mods[2048]; DWORD need = 0;
        if (EnumProcessModules(GetCurrentProcess(), mods, sizeof mods, &need)) {
            for (DWORD i = 0; i < need / sizeof(HMODULE); i++) {
                if (mods[i] == self) continue;
                char path[MAX_PATH]; GetModuleFileNameA(mods[i], path, sizeof path);
                if (!strstr(path, "\\PHtest\\")) continue;              /* game folder only */
                if (strstr(path, "AntiCheat") || strstr(path, "EasyAnti") || strstr(path, "Denuvo")) continue;
                int c = patchModule(mods[i]);
                if (c) { char *s = strrchr(path, '\\'); lg("patched %d imports in %s", c, s ? s + 1 : path); }
            }
        }
        Sleep(1000);
    }
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD why, LPVOID r) {
    (void)r;
    if (why != DLL_PROCESS_ATTACH) return TRUE;
    self = inst; DisableThreadLibraryCalls(inst);
    char path[MAX_PATH]; snprintf(path, sizeof path, DIR "trace-%lu.log", GetCurrentProcessId());
    logf = CreateFileA(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, CREATE_ALWAYS, 0, NULL);
    tls = TlsAlloc();
    quitSite = (ULONG_PTR)GetModuleHandleA(NULL) + 0x9fafd0;
    suppressQuit = GetEnvironmentVariableA("PVE_SUPPRESS_QUIT", NULL, 0) > 0;
    firstInstance = GetEnvironmentVariableA("PVE_FIRST_INSTANCE", NULL, 0) > 0;
    lg("pvetrace (IAT) in pid %lu: %s [suppressQuit=%d quitSite=%p]", GetCurrentProcessId(), GetCommandLineA(), suppressQuit, (void *)quitSite);
    CreateThread(NULL, 0, start, NULL, 0, NULL);
    return TRUE;
}
