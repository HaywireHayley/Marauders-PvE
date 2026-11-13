/*
 * pvenet.dll: the game's WinHTTP traffic (nakama-cpp and anything else that imports winhttp.dll) - logging, and
 * redirecting Nakama to the local stand-in backend. Loaded from the PvEBridge with package.loadlib(path, "*") when
 * bridge/capture_on or bridge/offline_backend exists:
 *   capture_on       log every request (below)
 *   offline_backend  WinHttpConnect to *.nakamacloud.io goes to 127.0.0.1:7350 instead (backend/nakama_standin.py),
 *                    as plain HTTP: WINHTTP_FLAG_SECURE is dropped and certificate options on those requests skipped;
 *                    and DNS lookups of anything but local names fail (see "offline: no live hosts").
 *
 * It rewrites the WinHTTP entries in every loaded module's import table to wrappers that call the real
 * function and record what passed through: host, verb, path, request headers (Authorization masked), request
 * body, status code, response headers and body. WinHTTP does TLS itself, so everything here is plain text.
 * Async requests (WINHTTP_FLAG_ASYNC) deliver their data through the status callback, which is wrapped too.
 * Logging modifies nothing. One JSON object per finished request goes to capture/winhttp-<time>.jsonl;
 * capture/pvenet.log says which modules were hooked.
 */
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <winhttp.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>
#include <psapi.h>

/* The project folder: this DLL is <project>\native\pvenet.dll. Logs go to <project>\capture\, flags are in
   <project>\bridge\. */
static char project[MAX_PATH];
static void at(char *out, size_t n, const char *rel) { snprintf(out, n, "%s%s", project, rel); }
#define STANDIN_HOST L"127.0.0.1"
#define STANDIN_PORT 7350

static CRITICAL_SECTION lock;
static FILE *out, *dbg;
static int offline;

/* ---- growable byte buffer ------------------------------------------------------------------------ */
typedef struct { char *p; size_t n, cap; } Buf;
static void put(Buf *b, const void *d, size_t n) {
    if (b->n + n + 1 > b->cap) {
        size_t c = b->cap ? b->cap * 2 : 256;
        while (c < b->n + n + 1) c *= 2;
        b->p = realloc(b->p, c); b->cap = c;
    }
    memcpy(b->p + b->n, d, n); b->n += n; b->p[b->n] = 0;
}
static void puts_(Buf *b, const char *s) { put(b, s, strlen(s)); }
static void wput(Buf *b, const wchar_t *w, int len) { /* UTF-16 -> UTF-8 */
    if (!w) return;
    if (len < 0) len = (int)wcslen(w);
    int n = WideCharToMultiByte(CP_UTF8, 0, w, len, NULL, 0, NULL, NULL);
    if (n <= 0) return;
    char *tmp = malloc(n);
    WideCharToMultiByte(CP_UTF8, 0, w, len, tmp, n, NULL, NULL);
    put(b, tmp, n); free(tmp);
}
/* JSON string; bytes outside printable ASCII except valid UTF-8 are written as \u00XX (one per byte). */
static void jstr(Buf *b, const char *s, size_t n) {
    puts_(b, "\"");
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        char e[8];
        if (c == '"' || c == '\\') { e[0] = '\\'; e[1] = c; put(b, e, 2); }
        else if (c == '\n') puts_(b, "\\n");
        else if (c == '\r') puts_(b, "\\r");
        else if (c == '\t') puts_(b, "\\t");
        else if (c < 0x20 || c == 0x7f) { sprintf(e, "\\u%04x", c); puts_(b, e); }
        else if (c >= 0x80) {
            int len = c >= 0xf0 ? 4 : c >= 0xe0 ? 3 : c >= 0xc0 ? 2 : 0, ok = len && i + len <= n;
            for (int k = 1; ok && k < len; k++) ok = ((unsigned char)s[i + k] & 0xc0) == 0x80;
            if (ok) { put(b, s + i, len); i += len - 1; }
            else { sprintf(e, "\\u%04x", c); puts_(b, e); }
        } else put(b, (char *)&c, 1);
    }
    puts_(b, "\"");
}

/* ---- per-handle state ---------------------------------------------------------------------------- */
typedef struct Req {
    HINTERNET h; struct Req *next;
    char host[256]; int port; char verb[16];
    Buf path, reqHead, reqBody, respBody;
    DWORD status; Buf respHead;
    LPVOID readBuf; double start;
    HINTERNET conn, sess;
    int local; /* sent to the stand-in backend */
} Req;
typedef struct Conn { HINTERNET h; struct Conn *next; char host[256]; int port; HINTERNET sess; int local; } Conn;
typedef struct Cb { HINTERNET h; struct Cb *next; WINHTTP_STATUS_CALLBACK fn; } Cb;
static Req *reqs; static Conn *conns; static Cb *cbs;
static int seq;

static Req *findReq(HINTERNET h) { for (Req *r = reqs; r; r = r->next) if (r->h == h) return r; return NULL; }
static Conn *findConn(HINTERNET h) { for (Conn *c = conns; c; c = c->next) if (c->h == h) return c; return NULL; }

static double now(void) { FILETIME f; GetSystemTimeAsFileTime(&f); return ((((ULONGLONG)f.dwHighDateTime << 32) | f.dwLowDateTime) / 1e7) - 11644473600.0; }

/* Masks the value of Authorization headers (keeps the scheme word). */
static void maskAuth(Buf *b) {
    for (char *p = b->p; p && (p = strstr(p, "uthorization:")); ) {
        p += 13;
        while (*p == ' ') p++;
        while (*p && *p != ' ' && *p != '\r' && *p != '\n') p++; /* scheme */
        while (*p && *p != '\r' && *p != '\n') *p++ = '*';
    }
}

static void finish(Req *r) {
    Buf j = {0};
    char tmp[512];
    sprintf(tmp, "{\"seq\":%d,\"t\":%.3f,\"ms\":%.0f,\"host\":", ++seq, r->start, (now() - r->start) * 1000);
    puts_(&j, tmp); jstr(&j, r->host, strlen(r->host));
    sprintf(tmp, ",\"port\":%d,\"verb\":", r->port); puts_(&j, tmp); jstr(&j, r->verb, strlen(r->verb));
    puts_(&j, ",\"path\":"); jstr(&j, r->path.p ? r->path.p : "", r->path.n);
    maskAuth(&r->reqHead); maskAuth(&r->respHead);
    puts_(&j, ",\"reqHeaders\":"); jstr(&j, r->reqHead.p ? r->reqHead.p : "", r->reqHead.n);
    puts_(&j, ",\"reqBody\":"); jstr(&j, r->reqBody.p ? r->reqBody.p : "", r->reqBody.n);
    sprintf(tmp, ",\"status\":%lu,\"respHeaders\":", (unsigned long)r->status); puts_(&j, tmp);
    jstr(&j, r->respHead.p ? r->respHead.p : "", r->respHead.n);
    puts_(&j, ",\"respBody\":"); jstr(&j, r->respBody.p ? r->respBody.p : "", r->respBody.n);
    puts_(&j, "}\n");
    if (out) { fwrite(j.p, 1, j.n, out); fflush(out); }
    free(j.p);
}

static void dropReq(HINTERNET h) {
    for (Req **pp = &reqs; *pp; pp = &(*pp)->next) if ((*pp)->h == h) {
        Req *r = *pp; *pp = r->next;
        finish(r);
        free(r->path.p); free(r->reqHead.p); free(r->reqBody.p); free(r->respBody.p); free(r->respHead.p); free(r);
        return;
    }
}

/* Response status + headers, read with the real API when they become available. */
static BOOL (WINAPI *rQueryHeaders)(HINTERNET, DWORD, LPCWSTR, LPVOID, LPDWORD, LPDWORD);
static void grabHeaders(Req *r) {
    DWORD st = 0, sz = sizeof st;
    if (rQueryHeaders(r->h, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, NULL, &st, &sz, NULL)) r->status = st;
    DWORD len = 0;
    rQueryHeaders(r->h, WINHTTP_QUERY_RAW_HEADERS_CRLF, NULL, NULL, &len, NULL);
    if (len) {
        wchar_t *w = malloc(len + 2);
        if (rQueryHeaders(r->h, WINHTTP_QUERY_RAW_HEADERS_CRLF, NULL, w, &len, NULL)) wput(&r->respHead, w, (int)(len / 2));
        free(w);
    }
}

/* ---- wrappers ------------------------------------------------------------------------------------ */
static HINTERNET (WINAPI *rConnect)(HINTERNET, LPCWSTR, INTERNET_PORT, DWORD);
static HINTERNET WINAPI hConnect(HINTERNET s, LPCWSTR server, INTERNET_PORT port, DWORD res) {
    int local = offline && server && wcsstr(server, L"nakamacloud.io");
    HINTERNET h = local ? rConnect(s, STANDIN_HOST, STANDIN_PORT, res) : rConnect(s, server, port, res);
    if (h) {
        Conn *c = calloc(1, sizeof *c); c->h = h; c->port = local ? STANDIN_PORT : port; c->sess = s; c->local = local;
        WideCharToMultiByte(CP_UTF8, 0, local ? STANDIN_HOST : server, -1, c->host, sizeof c->host - 1, NULL, NULL);
        EnterCriticalSection(&lock); c->next = conns; conns = c; LeaveCriticalSection(&lock);
    }
    return h;
}

static HINTERNET (WINAPI *rOpenRequest)(HINTERNET, LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR *, DWORD);
static HINTERNET WINAPI hOpenRequest(HINTERNET c, LPCWSTR verb, LPCWSTR obj, LPCWSTR ver, LPCWSTR ref, LPCWSTR *types, DWORD fl) {
    EnterCriticalSection(&lock);
    Conn *lc = findConn(c);
    int local = lc && lc->local;
    LeaveCriticalSection(&lock);
    if (local) fl &= ~WINHTTP_FLAG_SECURE;
    HINTERNET h = rOpenRequest(c, verb, obj, ver, ref, types, fl);
    if (h) {
        Req *r = calloc(1, sizeof *r); r->h = h; r->start = now(); r->local = local;
        EnterCriticalSection(&lock);
        Conn *cn = findConn(c);
        r->conn = c;
        if (cn) { strcpy(r->host, cn->host); r->port = cn->port; r->sess = cn->sess; }
        WideCharToMultiByte(CP_UTF8, 0, verb ? verb : L"GET", -1, r->verb, sizeof r->verb - 1, NULL, NULL);
        wput(&r->path, obj ? obj : L"/", -1);
        r->next = reqs; reqs = r;
        LeaveCriticalSection(&lock);
    }
    return h;
}

static BOOL (WINAPI *rAddHeaders)(HINTERNET, LPCWSTR, DWORD, DWORD);
static BOOL WINAPI hAddHeaders(HINTERNET h, LPCWSTR hd, DWORD len, DWORD mod) {
    EnterCriticalSection(&lock);
    Req *r = findReq(h);
    if (r && hd) { wput(&r->reqHead, hd, len == (DWORD)-1 ? -1 : (int)len); if (r->reqHead.n && r->reqHead.p[r->reqHead.n - 1] != '\n') puts_(&r->reqHead, "\r\n"); }
    LeaveCriticalSection(&lock);
    return rAddHeaders(h, hd, len, mod);
}

static BOOL (WINAPI *rSendRequest)(HINTERNET, LPCWSTR, DWORD, LPVOID, DWORD, DWORD, DWORD_PTR);
static BOOL WINAPI hSendRequest(HINTERNET h, LPCWSTR hd, DWORD hl, LPVOID opt, DWORD ol, DWORD total, DWORD_PTR ctx) {
    EnterCriticalSection(&lock);
    Req *r = findReq(h);
    if (r) {
        if (hd && hl) wput(&r->reqHead, hd, hl == (DWORD)-1 ? -1 : (int)hl);
        if (opt && ol) put(&r->reqBody, opt, ol);
    }
    LeaveCriticalSection(&lock);
    return rSendRequest(h, hd, hl, opt, ol, total, ctx);
}

static BOOL (WINAPI *rWriteData)(HINTERNET, LPCVOID, DWORD, LPDWORD);
static BOOL WINAPI hWriteData(HINTERNET h, LPCVOID d, DWORD n, LPDWORD wr) {
    EnterCriticalSection(&lock);
    Req *r = findReq(h);
    if (r && d && n) put(&r->reqBody, d, n);
    LeaveCriticalSection(&lock);
    return rWriteData(h, d, n, wr);
}

static BOOL (WINAPI *rReceiveResponse)(HINTERNET, LPVOID);
static BOOL WINAPI hReceiveResponse(HINTERNET h, LPVOID res) {
    BOOL ok = rReceiveResponse(h, res);
    EnterCriticalSection(&lock);
    Req *r = findReq(h);
    if (r && ok && !r->status) { /* synchronous handles have headers now; async ones get them in the callback */
        DWORD st = 0, sz = sizeof st;
        if (rQueryHeaders(h, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, NULL, &st, &sz, NULL)) grabHeaders(r);
    }
    LeaveCriticalSection(&lock);
    return ok;
}

static BOOL (WINAPI *rReadData)(HINTERNET, LPVOID, DWORD, LPDWORD);
static BOOL WINAPI hReadData(HINTERNET h, LPVOID buf, DWORD n, LPDWORD rd) {
    EnterCriticalSection(&lock);
    Req *r = findReq(h);
    if (r) r->readBuf = buf;
    LeaveCriticalSection(&lock);
    BOOL ok = rReadData(h, buf, n, rd);
    if (ok && rd && *rd) { /* synchronous read */
        EnterCriticalSection(&lock);
        r = findReq(h);
        if (r) put(&r->respBody, buf, *rd);
        LeaveCriticalSection(&lock);
    }
    return ok;
}

static void CALLBACK statusCb(HINTERNET h, DWORD_PTR ctx, DWORD st, LPVOID info, DWORD len) {
    WINHTTP_STATUS_CALLBACK real = NULL;
    EnterCriticalSection(&lock);
    Req *r = findReq(h);
    Conn *cn = r ? NULL : findConn(h);
    /* A callback set on a session (or connection) is inherited by the handles opened from it. */
    HINTERNET chain[3] = { h, r ? r->conn : cn ? cn->sess : NULL, r ? r->sess : NULL };
    for (int k = 0; k < 3 && !real; k++) if (chain[k]) for (Cb *c = cbs; c; c = c->next) if (c->h == chain[k]) { real = c->fn; break; }
    if (!real && cbs && !cbs->next) real = cbs->fn;
    if (r) {
        if (st == WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE) grabHeaders(r);
        else if (st == WINHTTP_CALLBACK_STATUS_READ_COMPLETE && info && len) put(&r->respBody, info, len);
    }
    LeaveCriticalSection(&lock);
    if (real) real(h, ctx, st, info, len);
}

static WINHTTP_STATUS_CALLBACK (WINAPI *rSetCallback)(HINTERNET, WINHTTP_STATUS_CALLBACK, DWORD, DWORD_PTR);
static WINHTTP_STATUS_CALLBACK WINAPI hSetCallback(HINTERNET h, WINHTTP_STATUS_CALLBACK fn, DWORD flags, DWORD_PTR res) {
    if (!fn || fn == (WINHTTP_STATUS_CALLBACK)(LONG_PTR)-1) return rSetCallback(h, fn, flags, res);
    EnterCriticalSection(&lock);
    Cb *c = calloc(1, sizeof *c); c->h = h; c->fn = fn; c->next = cbs; cbs = c;
    LeaveCriticalSection(&lock);
    rSetCallback(h, statusCb, flags | WINHTTP_CALLBACK_FLAG_HEADERS_AVAILABLE | WINHTTP_CALLBACK_FLAG_READ_COMPLETE, res);
    return NULL;
}

/* Certificate / TLS options make no sense on the plain-HTTP stand-in requests (they'd fail): pretend they worked. */
static BOOL (WINAPI *rSetOption)(HINTERNET, DWORD, LPVOID, DWORD);
static BOOL WINAPI hSetOption(HINTERNET h, DWORD opt, LPVOID buf, DWORD len) {
    if (opt == WINHTTP_OPTION_CLIENT_CERT_CONTEXT || opt == WINHTTP_OPTION_SECURITY_FLAGS
        || opt == WINHTTP_OPTION_SECURE_PROTOCOLS || opt == WINHTTP_OPTION_ENABLE_FEATURE) {
        EnterCriticalSection(&lock);
        Req *r = findReq(h);
        int local = r && r->local;
        LeaveCriticalSection(&lock);
        if (local) return TRUE;
    }
    return rSetOption(h, opt, buf, len);
}

static BOOL (WINAPI *rCloseHandle)(HINTERNET);
static BOOL WINAPI hCloseHandle(HINTERNET h) {
    EnterCriticalSection(&lock);
    dropReq(h);
    LeaveCriticalSection(&lock);
    return rCloseHandle(h);
}

/* ---- offline: no live hosts ----------------------------------------------------------------------- */
/* With offline_backend the game's own modules may only resolve local names: every other DNS lookup fails here
 * (WSAHOST_NOT_FOUND) and is logged with the calling module. That keeps raw-socket clients (Nakama's realtime
 * socket, matchmaking, EOS...) off the live services while mods are loaded. WinHTTP resolves inside winhttp.dll,
 * so the Nakama REST redirect above is unaffected; numeric addresses pass. */
static int localName(const char *n) {
    if (!n || !*n) return 1;
    if (!_stricmp(n, "localhost") || !_stricmp(n, "127.0.0.1") || !strcmp(n, "::1")) return 1;
    for (const char *c = n; *c; c++) if (!strchr("0123456789.:abcdefABCDEF", *c)) return 0; /* numeric v4/v6 */
    return strchr(n, '.') || strchr(n, ':');
}
static void blocked(const char *n, void *ret) {
    char mod[MAX_PATH] = "?"; HMODULE m;
    if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           (LPCSTR)ret, &m)) GetModuleFileNameA(m, mod, sizeof mod);
    const char *base = strrchr(mod, '\\');
    EnterCriticalSection(&lock);
    if (dbg) { time_t t = time(NULL); char ts[16]; strftime(ts, sizeof ts, "%H:%M:%S", localtime(&t));
               fprintf(dbg, "%s blocked lookup %s (from %s)\n", ts, n, base ? base + 1 : mod); fflush(dbg); }
    LeaveCriticalSection(&lock);
}
static void narrow(const wchar_t *w, char *out, int n) {
    if (!w) { out[0] = 0; return; }
    WideCharToMultiByte(CP_UTF8, 0, w, -1, out, n, NULL, NULL);
}

static INT (WSAAPI *rGetAddrInfo)(PCSTR, PCSTR, const ADDRINFOA *, PADDRINFOA *);
static INT WSAAPI hGetAddrInfo(PCSTR node, PCSTR svc, const ADDRINFOA *hints, PADDRINFOA *res) {
    if (offline && !localName(node)) { blocked(node, __builtin_return_address(0)); WSASetLastError(WSAHOST_NOT_FOUND);
                                       return WSAHOST_NOT_FOUND; }
    return rGetAddrInfo(node, svc, hints, res);
}
static INT (WSAAPI *rGetAddrInfoW)(PCWSTR, PCWSTR, const ADDRINFOW *, PADDRINFOW *);
static INT WSAAPI hGetAddrInfoW(PCWSTR node, PCWSTR svc, const ADDRINFOW *hints, PADDRINFOW *res) {
    char n[256]; narrow(node, n, sizeof n);
    if (offline && !localName(node ? n : NULL)) { blocked(n, __builtin_return_address(0));
                                                  WSASetLastError(WSAHOST_NOT_FOUND); return WSAHOST_NOT_FOUND; }
    return rGetAddrInfoW(node, svc, hints, res);
}
static INT (WSAAPI *rGetAddrInfoExW)(PCWSTR, PCWSTR, DWORD, LPGUID, const ADDRINFOEXW *, PADDRINFOEXW *,
                                     struct timeval *, LPOVERLAPPED, LPLOOKUPSERVICE_COMPLETION_ROUTINE, LPHANDLE);
static INT WSAAPI hGetAddrInfoExW(PCWSTR node, PCWSTR svc, DWORD ns, LPGUID id, const ADDRINFOEXW *hints,
                                  PADDRINFOEXW *res, struct timeval *to, LPOVERLAPPED ov,
                                  LPLOOKUPSERVICE_COMPLETION_ROUTINE cb, LPHANDLE h) {
    char n[256]; narrow(node, n, sizeof n);
    if (offline && !localName(node ? n : NULL)) { blocked(n, __builtin_return_address(0));
                                                  WSASetLastError(WSAHOST_NOT_FOUND); return WSAHOST_NOT_FOUND; }
    return rGetAddrInfoExW(node, svc, ns, id, hints, res, to, ov, cb, h);
}
static struct hostent *(WSAAPI *rGetHostByName)(const char *);
static struct hostent *WSAAPI hGetHostByName(const char *name) {
    if (offline && !localName(name)) { blocked(name, __builtin_return_address(0)); WSASetLastError(WSAHOST_NOT_FOUND);
                                       return NULL; }
    return rGetHostByName(name);
}

/* ---- import table patching ----------------------------------------------------------------------- */
typedef struct { const char *dll, *name; void *hook; void **real; } Hook;
static Hook HOOKS[] = {
    { "winhttp.dll", "WinHttpConnect", hConnect, (void **)&rConnect },
    { "winhttp.dll", "WinHttpOpenRequest", hOpenRequest, (void **)&rOpenRequest },
    { "winhttp.dll", "WinHttpAddRequestHeaders", hAddHeaders, (void **)&rAddHeaders },
    { "winhttp.dll", "WinHttpSendRequest", hSendRequest, (void **)&rSendRequest },
    { "winhttp.dll", "WinHttpWriteData", hWriteData, (void **)&rWriteData },
    { "winhttp.dll", "WinHttpReceiveResponse", hReceiveResponse, (void **)&rReceiveResponse },
    { "winhttp.dll", "WinHttpReadData", hReadData, (void **)&rReadData },
    { "winhttp.dll", "WinHttpSetStatusCallback", hSetCallback, (void **)&rSetCallback },
    { "winhttp.dll", "WinHttpCloseHandle", hCloseHandle, (void **)&rCloseHandle },
    { "winhttp.dll", "WinHttpSetOption", hSetOption, (void **)&rSetOption },
    { "ws2_32.dll", "getaddrinfo", hGetAddrInfo, (void **)&rGetAddrInfo },
    { "ws2_32.dll", "GetAddrInfoW", hGetAddrInfoW, (void **)&rGetAddrInfoW },
    { "ws2_32.dll", "GetAddrInfoExW", hGetAddrInfoExW, (void **)&rGetAddrInfoExW },
    { "ws2_32.dll", "gethostbyname", hGetHostByName, (void **)&rGetHostByName },
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
        if (_stricmp(dll, "winhttp.dll") && _stricmp(dll, "ws2_32.dll")) continue;
        if (!d->OriginalFirstThunk) continue;
        IMAGE_THUNK_DATA *names = (IMAGE_THUNK_DATA *)(b + d->OriginalFirstThunk);
        IMAGE_THUNK_DATA *iat = (IMAGE_THUNK_DATA *)(b + d->FirstThunk);
        /* Matched by the resolved address, not the name: ws2_32 is often imported by ordinal. */
        for (; names->u1.AddressOfData; names++, iat++) {
            for (int i = 0; i < NHOOKS; i++) if (*HOOKS[i].real && (void *)iat->u1.Function == *HOOKS[i].real) {
                DWORD prot;
                VirtualProtect(&iat->u1.Function, sizeof(void *), PAGE_READWRITE, &prot);
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
    HMODULE wh = LoadLibraryA("winhttp.dll"), ws = LoadLibraryA("ws2_32.dll");
    for (int i = 0; i < NHOOKS; i++)
        *HOOKS[i].real = (void *)GetProcAddress(_stricmp(HOOKS[i].dll, "ws2_32.dll") ? wh : ws, HOOKS[i].name);
    rQueryHeaders = (void *)GetProcAddress(wh, "WinHttpQueryHeaders");
    HMODULE self; GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS, (LPCSTR)start, &self);
    GetModuleFileNameA(self, project, sizeof project);
    for (char *c = project; *c; c++) if (*c == '/') *c = '\\'; /* package.loadlib was given a / path */
    for (int up = 0; up < 2; up++) { char *s = strrchr(project, '\\'); if (s) s[up ? 1 : 0] = 0; }
    /* The game's own folder (the one holding RaidGame\), from the exe: ...\RaidGame\Binaries\Win64\<exe>. */
    char game[MAX_PATH]; GetModuleFileNameA(NULL, game, sizeof game);
    for (int up = 0; up < 4; up++) { char *s = strrchr(game, '\\'); if (s) s[up == 3 ? 1 : 0] = 0; }
    size_t gameLen = strlen(game);
    char name[MAX_PATH] = "(off)", flag[MAX_PATH];
    at(flag, sizeof flag, "bridge\\offline_backend");
    offline = GetFileAttributesA(flag) != INVALID_FILE_ATTRIBUTES;
    at(flag, sizeof flag, "bridge\\capture_on");
    if (GetFileAttributesA(flag) != INVALID_FILE_ATTRIBUTES) {
        time_t t = time(NULL);
        char stamp[64];
        strftime(stamp, sizeof stamp, "capture\\winhttp-%Y%m%d-%H%M%S.jsonl", localtime(&t));
        at(name, sizeof name, stamp);
        out = fopen(name, "ab");
    }
    at(flag, sizeof flag, "capture\\pvenet.log");
    dbg = fopen(flag, "a");
    if (dbg) { fprintf(dbg, "nakama -> %s\n", offline ? "local stand-in 127.0.0.1:7350" : "live"); fflush(dbg); }
    /* Modules can load later (and the game may load nakama-cpp on demand): re-scan every few seconds. */
    for (int round = 0; ; round++) {
        HMODULE mods[1024]; DWORD need = 0;
        if (EnumProcessModules(GetCurrentProcess(), mods, sizeof mods, &need)) {
            for (DWORD i = 0; i < need / sizeof(HMODULE); i++) {
                if (mods[i] == self || mods[i] == wh || mods[i] == ws) continue;
                /* Only the game's own folder: never touch anti-cheat or other third-party injected modules. */
                char path[MAX_PATH]; GetModuleFileNameA(mods[i], path, sizeof path);
                if (_strnicmp(path, game, gameLen) || strstr(path, "AntiCheat") || strstr(path, "Denuvo")) continue;
                int n = patchModule(mods[i]);
                if (n && dbg) {
                    char mn[MAX_PATH]; GetModuleFileNameA(mods[i], mn, sizeof mn);
                    fprintf(dbg, "hooked %d winhttp/ws2_32 imports in %s\n", n, mn); fflush(dbg);
                }
            }
        }
        if (round == 0 && dbg) { fprintf(dbg, "logging to %s\n", name); fflush(dbg); }
        Sleep(3000);
    }
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD why, LPVOID r) {
    (void)h; (void)r;
    if (why == DLL_PROCESS_ATTACH) { InitializeCriticalSection(&lock); CreateThread(NULL, 0, start, NULL, 0, NULL); }
    return TRUE;
}
