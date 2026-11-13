/*
 * pveeac.dll: co-op join diagnostic, logging only. Loaded at launch (tracelaunch.exe pveeac.dll <exe> ...), it
 * IAT-hooks the exe's EOS anti-cheat SERVER imports and logs to capture/eac-<pid>.log what a listen host does with a
 * joining client: BeginSession, RegisterClient/UnregisterClient, and the ClientActionRequired / ClientAuthStatusChanged
 * notifications (wrapped so their action, reason and details text are logged before the game's own handler runs).
 * Every call is passed through unchanged. Only the exe's own import table is touched.
 */
#include <windows.h>
#include <stdio.h>
#include <stdint.h>

/* The project folder, with a trailing slash. native/build.sh passes it as -DPVE_ROOT="\"<folder>/\"". */
#ifndef PVE_ROOT
#define PVE_ROOT "C:/MaraudersPvE/"
#endif
#define DIR PVE_ROOT "capture/"
static FILE *out;
static CRITICAL_SECTION lock;
static void say(const char *fmt, ...) {
    if (!out) return;
    va_list a; va_start(a, fmt);
    EnterCriticalSection(&lock);
    fprintf(out, "%lu ", GetTickCount()); vfprintf(out, fmt, a); fputc('\n', out); fflush(out);
    LeaveCriticalSection(&lock);
    va_end(a);
}

/* EOS SDK shapes (eos_anticheatcommon_types.h / eos_anticheatserver_types.h). */
typedef struct { void *ClientData; void *ClientHandle; int32_t ClientAction; int32_t ActionReason; const char *Details; } ActionInfo;
typedef struct { void *ClientData; void *ClientHandle; int32_t Status; } AuthInfo;
typedef void (*ActionFn)(const ActionInfo *);
typedef void (*AuthFn)(const AuthInfo *);
typedef struct { int32_t ApiVersion; void *ClientHandle; int32_t ClientType; int32_t ClientPlatform; const char *AccountId;
                 const char *IpAddress; } RegisterOpts; /* enough of RegisterClient's options to name the client */

static ActionFn gameAction; static AuthFn gameAuth;
static void myAction(const ActionInfo *i) {
    say("ClientActionRequired client=%p action=%d reason=%d details=%s", i->ClientHandle, i->ClientAction, i->ActionReason,
        i->Details ? i->Details : "(null)");
    if (gameAction) gameAction(i);
}
static void myAuth(const AuthInfo *i) {
    say("ClientAuthStatusChanged client=%p status=%d", i->ClientHandle, i->Status);
    if (gameAuth) gameAuth(i);
}

static uint64_t (*rAddAction)(void *, const void *, void *, ActionFn);
static uint64_t hAddAction(void *h, const void *o, void *cd, ActionFn fn) {
    gameAction = fn; uint64_t r = rAddAction(h, o, cd, myAction);
    say("AddNotifyClientActionRequired -> id %llu", (unsigned long long)r); return r;
}
static uint64_t (*rAddAuth)(void *, const void *, void *, AuthFn);
static uint64_t hAddAuth(void *h, const void *o, void *cd, AuthFn fn) {
    gameAuth = fn; uint64_t r = rAddAuth(h, o, cd, myAuth);
    say("AddNotifyClientAuthStatusChanged -> id %llu", (unsigned long long)r); return r;
}
static int32_t (*rBegin)(void *, const void *);
static int32_t hBegin(void *h, const void *o) { int32_t r = rBegin(h, o); say("BeginSession -> %d", r); return r; }
static int32_t (*rEnd)(void *, const void *);
static int32_t hEnd(void *h, const void *o) { int32_t r = rEnd(h, o); say("EndSession -> %d", r); return r; }
static int32_t (*rRegister)(void *, const RegisterOpts *);
static int32_t hRegister(void *h, const RegisterOpts *o) {
    int32_t r = rRegister(h, o);
    say("RegisterClient client=%p type=%d platform=%d account=%s ip=%s -> %d", o ? o->ClientHandle : 0, o ? o->ClientType : -1,
        o ? o->ClientPlatform : -1, o && o->AccountId ? o->AccountId : "(null)", o && o->IpAddress ? o->IpAddress : "(null)", r);
    return r;
}
static int32_t (*rUnregister)(void *, const void *);
static int32_t hUnregister(void *h, const void *o) { int32_t r = rUnregister(h, o); say("UnregisterClient -> %d", r); return r; }

typedef struct { const char *name; void *hook; void **real; } Hook;
static Hook HOOKS[] = {
    { "EOS_AntiCheatServer_AddNotifyClientActionRequired", hAddAction, (void **)&rAddAction },
    { "EOS_AntiCheatServer_AddNotifyClientAuthStatusChanged", hAddAuth, (void **)&rAddAuth },
    { "EOS_AntiCheatServer_BeginSession", hBegin, (void **)&rBegin },
    { "EOS_AntiCheatServer_EndSession", hEnd, (void **)&rEnd },
    { "EOS_AntiCheatServer_RegisterClient", hRegister, (void **)&rRegister },
    { "EOS_AntiCheatServer_UnregisterClient", hUnregister, (void **)&rUnregister },
};
#define NHOOKS (int)(sizeof HOOKS / sizeof HOOKS[0])

/* The game loads EOSSDK at runtime and looks its functions up by name, so the hook point is the exe's own
 * GetProcAddress import: for the names above it returns our pass-through wrapper (and keeps the real address). */
static FARPROC (WINAPI *rGetProcAddress)(HMODULE, LPCSTR);
static FARPROC WINAPI hGetProcAddress(HMODULE m, LPCSTR name) {
    FARPROC r = rGetProcAddress(m, name);
    if (r && (ULONG_PTR)name > 0xffff && !strncmp(name, "EOS_AntiCheatServer_", 20))
        for (int i = 0; i < NHOOKS; i++) if (!strcmp(name, HOOKS[i].name)) {
            *HOOKS[i].real = (void *)r; say("resolved %s", name); return (FARPROC)HOOKS[i].hook;
        }
    return r;
}

static int patchExe(void) {
    unsigned char *b = (unsigned char *)GetModuleHandleA(NULL);
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(b + ((IMAGE_DOS_HEADER *)b)->e_lfanew);
    IMAGE_DATA_DIRECTORY dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    int n = 0;
    for (IMAGE_IMPORT_DESCRIPTOR *d = (IMAGE_IMPORT_DESCRIPTOR *)(b + dir.VirtualAddress); d->Name; d++) {
        if (_stricmp((char *)(b + d->Name), "kernel32.dll")) continue;
        for (IMAGE_THUNK_DATA *iat = (IMAGE_THUNK_DATA *)(b + d->FirstThunk); iat->u1.Function; iat++)
            if ((void *)iat->u1.Function == (void *)rGetProcAddress) {
                DWORD prot;
                VirtualProtect(&iat->u1.Function, sizeof(void *), PAGE_READWRITE, &prot);
                iat->u1.Function = (ULONG_PTR)hGetProcAddress;
                VirtualProtect(&iat->u1.Function, sizeof(void *), prot, &prot);
                n++;
            }
    }
    return n;
}

static DWORD WINAPI start(LPVOID p) {
    (void)p;
    char path[MAX_PATH]; snprintf(path, sizeof path, DIR "eac-%lu.log", GetCurrentProcessId());
    out = fopen(path, "w");
    rGetProcAddress = (void *)GetProcAddress(GetModuleHandleA("kernel32.dll"), "GetProcAddress");
    /* Started before the process has run: wait until the exe's imports are bound, then swap GetProcAddress. */
    for (int t = 0; t < 1500; t++) {
        int n = patchExe();
        if (n) { say("hooked GetProcAddress in the exe (%d)", n); return 0; }
        Sleep(2);
    }
    say("GetProcAddress import not found");
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD why, LPVOID r) {
    (void)h; (void)r;
    if (why == DLL_PROCESS_ATTACH) { InitializeCriticalSection(&lock); CreateThread(NULL, 0, start, NULL, 0, NULL); }
    return TRUE;
}
