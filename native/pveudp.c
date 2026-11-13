/*
 * pveudp.dll: co-op join diagnostic. Inject into a running copy (tracelaunch.exe -p <pid> pveudp.dll); it IAT-hooks the
 * game exe's ws2_32 sendto/recvfrom/WSASendTo/WSARecvFrom and logs every UDP datagram to or from 127.0.0.1 (the local
 * co-op peer) as hex to capture/udp-<pid>.log, so the handshake (and a rejection message the server sends back)
 * can be decoded offline (scripts/udpstr.py). Only the exe's own import table is touched. Stops after 4000 packets.
 */
#include <winsock2.h>
#include <windows.h>
#include <stdio.h>

/* The project folder, with a trailing slash. native/build.sh passes it as -DPVE_ROOT="\"<folder>/\"". */
#ifndef PVE_ROOT
#define PVE_ROOT "C:/MaraudersPvE/"
#endif
#define DIR PVE_ROOT "capture/"
static FILE *out;
static CRITICAL_SECTION lock;
static int count;

static void logpkt(const char *dir, const struct sockaddr *a, const char *buf, int len) {
    if (!out || len <= 0 || !a || a->sa_family != AF_INET) return;
    const struct sockaddr_in *in = (const struct sockaddr_in *)a;
    if (in->sin_addr.s_addr != htonl(INADDR_LOOPBACK)) return;
    EnterCriticalSection(&lock);
    if (count++ < 4000) {
        fprintf(out, "%lu %s port=%u len=%d ", GetTickCount(), dir, ntohs(in->sin_port), len);
        for (int i = 0; i < len; i++) fprintf(out, "%02x", (unsigned char)buf[i]);
        fputc('\n', out); fflush(out);
    }
    LeaveCriticalSection(&lock);
}

/* Who sends: a closing connection flushes its last packet synchronously, so the stack of that sendto holds the code
 * that closed it. Each distinct chain of return addresses (stack scan; exe code has no unwind data) is logged once
 * as STACK module+offset lines, so the close path stands out from the per-tick flush path. */
static char seen[64][1200]; static int nseen;
static void where(ULONG_PTR p, char *o, int n) {
    HMODULE m = NULL; char path[MAX_PATH];
    if (!GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCSTR)p, &m) || !m) {
        o[0] = 0; return;
    }
    GetModuleFileNameA(m, path, MAX_PATH); char *s = strrchr(path, '\\');
    snprintf(o, n, "%s+%llx", s ? s + 1 : path, (unsigned long long)(p - (ULONG_PTR)m));
}
static void logstack(const struct sockaddr *a) {
    if (!out || !a || a->sa_family != AF_INET || ((const struct sockaddr_in *)a)->sin_addr.s_addr != htonl(INADDR_LOOPBACK)) return;
    ULONG_PTR *sp = (ULONG_PTR *)&a, lo, hi;
    GetCurrentThreadStackLimits(&lo, &hi);
    char sig[1200] = ""; int len = 0, shown = 0;
    for (int k = 0; k < 3000 && shown < 28 && (ULONG_PTR)(sp + k) < hi; k++) {
        ULONG_PTR v = sp[k]; MEMORY_BASIC_INFORMATION mi;
        if (v < 0x10000 || !VirtualQuery((void *)v, &mi, sizeof mi)) continue;
        if (!(mi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))) continue;
        char w[300]; where(v, w, sizeof w);
        if (!w[0] || !strncmp(w, "pveudp", 6)) continue;
        len += snprintf(sig + len, sizeof sig - len, " %s", w); shown++;
        if (len > (int)sizeof sig - 80) break;
    }
    EnterCriticalSection(&lock);
    int dup = 0;
    for (int i = 0; i < nseen; i++) if (!strcmp(seen[i], sig)) { dup = 1; break; }
    if (!dup && nseen < 64) {
        strcpy(seen[nseen++], sig);
        fprintf(out, "%lu STACK%s\n", GetTickCount(), sig); fflush(out);
    }
    LeaveCriticalSection(&lock);
}

static int (WSAAPI *rSendTo)(SOCKET, const char *, int, int, const struct sockaddr *, int);
static int WSAAPI hSendTo(SOCKET s, const char *b, int n, int f, const struct sockaddr *to, int tl) {
    int r = rSendTo(s, b, n, f, to, tl);
    if (r > 0) { logstack(to); logpkt("OUT", to, b, r); }
    return r;
}
static int (WSAAPI *rRecvFrom)(SOCKET, char *, int, int, struct sockaddr *, int *);
static int WSAAPI hRecvFrom(SOCKET s, char *b, int n, int f, struct sockaddr *from, int *fl) {
    int r = rRecvFrom(s, b, n, f, from, fl);
    if (r > 0) logpkt("IN ", from, b, r);
    return r;
}
static int (WSAAPI *rWSASendTo)(SOCKET, LPWSABUF, DWORD, LPDWORD, DWORD, const struct sockaddr *, int, LPWSAOVERLAPPED,
                                LPWSAOVERLAPPED_COMPLETION_ROUTINE);
static int WSAAPI hWSASendTo(SOCKET s, LPWSABUF bufs, DWORD nb, LPDWORD sent, DWORD f, const struct sockaddr *to, int tl,
                             LPWSAOVERLAPPED ov, LPWSAOVERLAPPED_COMPLETION_ROUTINE cr) {
    int r = rWSASendTo(s, bufs, nb, sent, f, to, tl, ov, cr);
    if (r == 0 && nb) logpkt("OUT", to, bufs[0].buf, (int)bufs[0].len);
    return r;
}
static int (WSAAPI *rWSARecvFrom)(SOCKET, LPWSABUF, DWORD, LPDWORD, LPDWORD, struct sockaddr *, LPINT, LPWSAOVERLAPPED,
                                  LPWSAOVERLAPPED_COMPLETION_ROUTINE);
static int WSAAPI hWSARecvFrom(SOCKET s, LPWSABUF bufs, DWORD nb, LPDWORD got, LPDWORD f, struct sockaddr *from, LPINT fl,
                               LPWSAOVERLAPPED ov, LPWSAOVERLAPPED_COMPLETION_ROUTINE cr) {
    int r = rWSARecvFrom(s, bufs, nb, got, f, from, fl, ov, cr);
    if (r == 0 && nb && got && !ov) logpkt("IN ", from, bufs[0].buf, (int)*got);
    return r;
}

typedef struct { const char *name; void *hook; void **real; } Hook;
static Hook HOOKS[] = {
    { "sendto", hSendTo, (void **)&rSendTo },
    { "recvfrom", hRecvFrom, (void **)&rRecvFrom },
    { "WSASendTo", hWSASendTo, (void **)&rWSASendTo },
    { "WSARecvFrom", hWSARecvFrom, (void **)&rWSARecvFrom },
};
#define NHOOKS (int)(sizeof HOOKS / sizeof HOOKS[0])

static int patchModule(HMODULE m) {
    unsigned char *b = (unsigned char *)m;
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(b + ((IMAGE_DOS_HEADER *)b)->e_lfanew);
    IMAGE_DATA_DIRECTORY dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (!dir.VirtualAddress) return 0;
    int n = 0;
    for (IMAGE_IMPORT_DESCRIPTOR *d = (IMAGE_IMPORT_DESCRIPTOR *)(b + dir.VirtualAddress); d->Name; d++) {
        if (_stricmp((char *)(b + d->Name), "ws2_32.dll")) continue;
        /* Matched by resolved address: ws2_32 is often imported by ordinal. */
        for (IMAGE_THUNK_DATA *iat = (IMAGE_THUNK_DATA *)(b + d->FirstThunk); iat->u1.Function; iat++)
            for (int i = 0; i < NHOOKS; i++) if (*HOOKS[i].real && (void *)iat->u1.Function == *HOOKS[i].real) {
                DWORD prot;
                VirtualProtect(&iat->u1.Function, sizeof(void *), PAGE_READWRITE, &prot);
                iat->u1.Function = (ULONG_PTR)HOOKS[i].hook;
                VirtualProtect(&iat->u1.Function, sizeof(void *), prot, &prot);
                n++;
            }
    }
    return n;
}

static DWORD WINAPI start(LPVOID p) {
    (void)p;
    HMODULE ws = LoadLibraryA("ws2_32.dll");
    for (int i = 0; i < NHOOKS; i++) *HOOKS[i].real = (void *)GetProcAddress(ws, HOOKS[i].name);
    char path[MAX_PATH]; snprintf(path, sizeof path, DIR "udp-%lu.log", GetCurrentProcessId());
    out = fopen(path, "w");
    int n = patchModule(GetModuleHandleA(NULL));
    if (out) { fprintf(out, "hooked %d ws2_32 imports in the exe\n", n); fflush(out); }
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD why, LPVOID r) {
    (void)h; (void)r;
    if (why == DLL_PROCESS_ATTACH) { InitializeCriticalSection(&lock); CreateThread(NULL, 0, start, NULL, 0, NULL); }
    return TRUE;
}
