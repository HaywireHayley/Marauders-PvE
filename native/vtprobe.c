/* vtprobe.c - co-op research probe (issue #26): finds engine objects by vtable and samples their memory.
 *
 * Load it into the game with `lua package.loadlib("<repo>/native/vtprobe.dll", "*")` from the bridge; DllMain starts
 * a worker thread that polls a command file. Never needed to play.
 *
 * Files (directory = env VTH_DIR, else <repo>/bridge/ baked in at build time):
 *   vth_cmd.txt   one command per line; the probe renames it to vth_cmd.work, runs it, deletes it
 *   vth_out.txt   appended log, one line per result, stamped with QueryPerformanceCounter ms (system-wide, so the
 *                 logs of a host and a client merge onto one timeline)
 * Give each game instance its own VTH_DIR (both load the same DLL). A loaded DLL is locked: to load a rebuilt copy
 * beside it, build it under another name with -DPREFIX="\"vtx\"" so it reads its own command file.
 *
 * Catching a client's join (what found the "PlayerNick is null" refusal, #26), from the client's bridge before `join`:
 *   lua package.loadlib(".../vtprobe.dll","*") NotifyOnNewObject("/Script/OnlineSubsystemUtils.IpNetDriver",
 *       function(o) <write "watch=0x<o:GetAddress()>:12" to VTH_DIR/vth_cmd.txt> end)
 * after writing "period=1" and "bpconn=1" to the command file.
 *
 * Commands (numbers are hex with 0x, secs decimal):
 *   base=1                          module base of the game exe
 *   read=0xADDR:0xLEN               qwords at ADDR (each read is checked, never faults)
 *   scan=0xVT[:secs]                every object whose first qword is VT, with Class and flags, for secs (default 0
 *                                   = one pass)
 *   ndscan=0xVT[:secs[:0xCLASS]]    live UNetDrivers only (see isDriver), then samples ServerConnection at 10 Hz
 *   watch=0xADDR[:secs]             a driver known by address (Lua NotifyOnNewObject): waits for ServerConnection,
 *                                   then samples it at 10 Hz. The way to catch a client's join: a scan pass over a
 *                                   5.6 GB heap takes ~10 s, the join lasts ~3 s
 *   bpconn=1                        watch= also puts a hardware write-watch (DR0) on the connection's State byte and
 *                                   logs each writer's call stack as module+offset (BPHIT lines)
 *   bpw=0xADDR / bpclear            the same write-watch on any address, and off again
 *   bpx=0xRVA / bphits              execute breakpoint at exe+RVA (stack and FStrings on the stack logged per hit, up
 *                                   to 8); bphits logs what has been recorded so far
 *   period=N                        sampling period in ms for watch/drv/conn; under 100 only changes are logged
 *   drv=0xADDR[:secs]               samples a driver's ClientConnections at 10 Hz (server side)
 *   conn=0xADDR[:secs]              samples one UNetConnection at 10 Hz, diffing its first 0x800 bytes
 *
 * The first version of this probe (never committed, source lost) stopped at the first vtable match, and that match
 * was the copy of VT on its own thread's stack (NOTES.md, "The NetDriver scan was finding its own stack"). This one
 * skips its own stack and buffers, and accepts a driver only by Class, object flags and NetDriverName.
 *
 * Build (WinLibs MinGW-w64, as native/build.sh):
 *   gcc -shared -O2 -Wall -Wextra -DPVE_ROOT="\"$(pwd -W)/\"" -o native/vtprobe.dll native/vtprobe.c
 */
#define _WIN32_WINNT 0x0602
#include <windows.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdarg.h>
#include <tlhelp32.h>

#ifndef PVE_ROOT
#define PVE_ROOT ""
#endif
#ifndef PREFIX          /* -DPREFIX="\"vtx\"" gives a copy its own command file, so it can load beside an older one */
#define PREFIX "vth"
#endif

/* Offsets from the game's own reflection dump (sdk verb), checked live on a listen host 2026-11-19. */
#define OFF_FLAGS        0x08   /* UObject::ObjectFlags (int32) */
#define OFF_CLASS        0x10   /* UObject::ClassPrivate */
#define OFF_SERVERCONN   0x88   /* UNetDriver::ServerConnection */
#define OFF_CLIENTCONNS  0x90   /* UNetDriver::ClientConnections (TArray: Data, Num, Max) */
#define OFF_WORLD        0x140  /* UNetDriver::World */
#define OFF_DRIVERNAME   0x190  /* UNetDriver::NetDriverName (FName: ComparisonIndex, Number) */
#define OFF_CONN_DRIVER  0x58   /* UNetConnection::Driver */
#define OFF_CONN_LRT     0x1D0  /* UNetConnection::LastReceiveTime (double) */
#define OFF_CONN_STATE   0x134  /* candidate UNetConnection::State (byte; 1 Closed, 2 Pending, 3 Open) - unconfirmed */
#define RF_CDO           0x10   /* RF_ClassDefaultObject */
#define NAME_GAMENETDRIVER 0x2e8 /* FName index that reads "GameNetDriver" on this build */
#define DIFF_LEN         0x800

static char g_dir[MAX_PATH];
static uint8_t *g_buf;            /* scan chunk buffer; its own region is skipped */
static int g_period = 100;        /* sampling period, ms (period=N); below 100 only changes are logged, no diffs */
static int g_bpconn;              /* bpconn=1: watch= puts a hardware write-watch on the connection's State byte */
#define CHUNK (1u << 20)

/* ---- hardware write-watch (DR0, 1 byte) with a stack unwind of whoever writes ----
 * The handler only records into this table; the worker thread formats and logs it. */
#define BP_MAX 8
#define BP_FRAMES 28
#define BP_STRS 6
struct bphit { DWORD tid; uint8_t val; DWORD64 frames[BP_FRAMES]; int n; wchar_t strs[BP_STRS][160]; int ns; };

/* FStrings ({wchar_t *Data, int32 Num, int32 Max}) on the writer's stack, copied while they are still alive:
 * the reason a caller passes along (an error message) is usually one of them. */
static void grabStrings(struct bphit *h, DWORD64 rsp, size_t span)
{
    for (size_t off = 0; off + 16 <= span && h->ns < BP_STRS; off += 8) {
        struct { uint64_t data; int32_t num, max; } fs;
        SIZE_T got = 0;
        if (!ReadProcessMemory(GetCurrentProcess(), (LPCVOID)(uintptr_t)(rsp + off), &fs, 16, &got)) break;
        if (fs.num < 2 || fs.num > 159 || fs.max < fs.num || fs.max > 4096 || fs.data < 0x10000) continue;
        wchar_t w[160];
        if (!ReadProcessMemory(GetCurrentProcess(), (LPCVOID)(uintptr_t)fs.data, w, (size_t)fs.num * 2, &got)) continue;
        if (w[fs.num - 1] != 0) continue;
        int ok = 1;
        for (int i = 0; i < fs.num - 1 && ok; i++) ok = w[i] >= 32 && w[i] < 0x2000;
        if (!ok) continue;
        memcpy(h->strs[h->ns++], w, (size_t)fs.num * 2);
    }
}
static struct bphit g_hits[BP_MAX];
static volatile LONG g_nhits, g_logged;
static volatile uint64_t g_bpaddr;
static volatile int g_bpexec;          /* DR0 is an execute breakpoint (bpx=) rather than a write-watch */
static PVOID g_veh;

static LONG CALLBACK bpHandler(PEXCEPTION_POINTERS ep)
{
    if (ep->ExceptionRecord->ExceptionCode != EXCEPTION_SINGLE_STEP || !(ep->ContextRecord->Dr6 & 1))
        return EXCEPTION_CONTINUE_SEARCH;
    ep->ContextRecord->Dr6 = 0;
    if (g_bpexec) ep->ContextRecord->EFlags |= 0x10000;   /* RF: run the instruction instead of trapping again */
    LONG i = InterlockedIncrement(&g_nhits) - 1;
    if (i < BP_MAX && g_bpaddr) {
        struct bphit *h = &g_hits[i];
        h->tid = GetCurrentThreadId();
        h->val = *(volatile uint8_t *)(uintptr_t)g_bpaddr;
        CONTEXT c = *ep->ContextRecord;
        h->ns = 0;
        grabStrings(h, c.Rsp, g_bpexec ? 0x1000 : 0x600);
        int n = 0;
        while (n < BP_FRAMES && c.Rip) {
            h->frames[n++] = c.Rip;
            DWORD64 imageBase = 0;
            PRUNTIME_FUNCTION rf = RtlLookupFunctionEntry(c.Rip, &imageBase, NULL);
            if (rf) {
                PVOID hd; DWORD64 ef;
                RtlVirtualUnwind(UNW_FLAG_NHANDLER, imageBase, c.Rip, rf, &c, &hd, &ef, NULL);
            } else {                                   /* leaf: return address on top of the stack */
                DWORD64 ret = 0;
                SIZE_T got = 0;
                if (!ReadProcessMemory(GetCurrentProcess(), (LPCVOID)(uintptr_t)c.Rsp, &ret, 8, &got)) break;
                c.Rip = ret;
                c.Rsp += 8;
            }
        }
        h->n = n;
    }
    return EXCEPTION_CONTINUE_EXECUTION;
}

/* Points DR0 at addr (1-byte write) on every other thread of the process; addr 0 turns it off. */
static int setWatchKind(uint64_t addr, int exec)
{
    g_bpexec = exec;
    if (!g_veh) g_veh = AddVectoredExceptionHandler(1, bpHandler);
    g_bpaddr = addr;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    if (snap == INVALID_HANDLE_VALUE) return 0;
    THREADENTRY32 te = { .dwSize = sizeof te };
    DWORD pid = GetCurrentProcessId(), self = GetCurrentThreadId();
    int done = 0;
    for (BOOL ok = Thread32First(snap, &te); ok; ok = Thread32Next(snap, &te)) {
        if (te.th32OwnerProcessID != pid || te.th32ThreadID == self) continue;
        HANDLE t = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_SET_CONTEXT, FALSE, te.th32ThreadID);
        if (!t) continue;
        if (SuspendThread(t) != (DWORD)-1) {
            CONTEXT c = { .ContextFlags = CONTEXT_DEBUG_REGISTERS };
            if (GetThreadContext(t, &c)) {
                c.Dr0 = addr;
                /* L0; RW0 = 01 write or 00 execute; LEN0 = 00 (1 byte) */
                c.Dr7 = (c.Dr7 & ~(0xFULL << 16) & ~1ULL) | (addr ? (1ULL | (exec ? 0 : 1ULL << 16)) : 0);
                if (SetThreadContext(t, &c)) done++;
            }
            ResumeThread(t);
        }
        CloseHandle(t);
    }
    CloseHandle(snap);
    return done;
}

static int setWatch(uint64_t addr) { return setWatchKind(addr, 0); }

static void plog(const char *fmt, ...);

/* Logs hits the handler recorded since the last call, frames as module+offset. */
static void flushHits(void)
{
    LONG n = g_nhits < BP_MAX ? g_nhits : BP_MAX;
    for (; g_logged < n; g_logged++) {
        struct bphit *h = &g_hits[g_logged];
        char buf[4096];
        size_t o = 0;
        buf[0] = 0;
        for (int i = 0; i < h->n; i++) {
            HMODULE m = NULL;
            char name[MAX_PATH] = "?";
            if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                                   (LPCSTR)(uintptr_t)h->frames[i], &m) && m) {
                GetModuleFileNameA(m, name, sizeof name);
                char *b = strrchr(name, '\\');
                o += snprintf(buf + o, sizeof buf - o, " %s+%llx", b ? b + 1 : name,
                              (unsigned long long)(h->frames[i] - (uintptr_t)m));
            } else o += snprintf(buf + o, sizeof buf - o, " %llx", (unsigned long long)h->frames[i]);
        }
        plog("BPHIT %ld tid=%lu val=%u frames:%s", g_logged, h->tid, h->val, buf);
        for (int i = 0; i < h->ns; i++) {
            char a[400];
            WideCharToMultiByte(CP_UTF8, 0, h->strs[i], -1, a, sizeof a, NULL, NULL);
            plog("BPHIT %ld str %d \"%s\"", g_logged, i, a);
        }
    }
}

static void plog(const char *fmt, ...)
{
    char path[MAX_PATH + 32], line[12288];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    snprintf(path, sizeof path, "%s" PREFIX "_out.txt", g_dir);
    FILE *f = fopen(path, "ab");
    if (!f) return;
    /* QueryPerformanceCounter is system-wide, so lines from two instances line up to well under a millisecond */
    LARGE_INTEGER now, hz;
    QueryPerformanceCounter(&now);
    QueryPerformanceFrequency(&hz);
    fprintf(f, "%.3f %s\n", (double)now.QuadPart * 1000.0 / (double)hz.QuadPart, line);
    fclose(f);
}

/* Checked read: ReadProcessMemory on our own process fails instead of faulting on a bad address. */
static int rd(uint64_t addr, void *out, size_t n)
{
    SIZE_T got = 0;
    if (!addr) return 0;
    return ReadProcessMemory(GetCurrentProcess(), (LPCVOID)(uintptr_t)addr, out, n, &got) && got == n;
}

static uint64_t rq(uint64_t addr)
{
    uint64_t v = 0;
    return rd(addr, &v, 8) ? v : 0;
}

/* A live game NetDriver: right vtable, not the CDO, optional Class match, named GameNetDriver. */
static int isDriver(uint64_t obj, uint64_t cls)
{
    uint32_t flags = 0, name[2] = {0, 0};
    if (!rd(obj + OFF_FLAGS, &flags, 4) || (flags & RF_CDO)) return 0;
    if (cls && rq(obj + OFF_CLASS) != cls) return 0;
    if (!rd(obj + OFF_DRIVERNAME, name, 8)) return 0;
    return name[0] == NAME_GAMENETDRIVER;
}

typedef int (*hitfn)(uint64_t obj, void *ctx);   /* return nonzero to stop the pass */

/* One pass over committed private read-write memory for qwords equal to vt, skipping this thread's stack and the
 * scan buffer (both hold copies of vt). Returns the number of matches handed to fn. */
static int scanPass(uint64_t vt, hitfn fn, void *ctx)
{
    ULONG_PTR stLo = 0, stHi = 0;
    GetCurrentThreadStackLimits(&stLo, &stHi);
    MEMORY_BASIC_INFORMATION mi;
    uint8_t *p = 0;
    int hits = 0;
    while (VirtualQuery(p, &mi, sizeof mi) == sizeof mi) {
        uint8_t *base = (uint8_t *)mi.BaseAddress, *end = base + mi.RegionSize;
        int rw = mi.State == MEM_COMMIT && mi.Type == MEM_PRIVATE && !(mi.Protect & (PAGE_GUARD | PAGE_NOACCESS))
            && (mi.Protect & (PAGE_READWRITE | PAGE_EXECUTE_READWRITE));
        int own = (uintptr_t)base < stHi && (uintptr_t)end > stLo;
        own |= base <= g_buf && end > g_buf;
        if (rw && !own) {
            for (uint8_t *c = base; c < end; c += CHUNK) {
                size_t n = (size_t)(end - c) < CHUNK ? (size_t)(end - c) : CHUNK;
                if (!rd((uint64_t)(uintptr_t)c, g_buf, n)) continue;
                for (size_t i = 0; i + 8 <= n; i += 8)
                    if (*(uint64_t *)(g_buf + i) == vt) {
                        hits++;
                        if (fn((uint64_t)(uintptr_t)(c + i), ctx)) return hits;
                    }
            }
        }
        if (end <= p) break;
        p = end;
    }
    return hits;
}

/* ---- scan= : report everything, so a filter can be chosen from evidence ---- */
static int scanReport(uint64_t obj, void *ctx)
{
    int *pass = ctx;
    uint32_t flags = 0, name[2] = {0, 0};
    rd(obj + OFF_FLAGS, &flags, 4);
    rd(obj + OFF_DRIVERNAME, name, 8);
    plog("SCANHIT pass=%d obj=%llx flags=%x cls=%llx +88=%llx +190=%x", *pass, (unsigned long long)obj, flags,
         (unsigned long long)rq(obj + OFF_CLASS), (unsigned long long)rq(obj + OFF_SERVERCONN), name[0]);
    return 0;
}

static void cmdScan(uint64_t vt, int secs)
{
    plog("SCAN start vt=%llx secs=%d", (unsigned long long)vt, secs);
    DWORD until = GetTickCount() + secs * 1000u;
    int pass = 0;
    do {
        DWORD t = GetTickCount();
        int n = scanPass(vt, scanReport, &pass);
        plog("SCAN pass=%d hits=%d ms=%lu", pass, n, GetTickCount() - t);
        pass++;
    } while ((int)(until - GetTickCount()) > 0);
}

/* ---- connection sampling ---- */
static void sampleConn(uint64_t conn, uint64_t drv, int secs, const char *tag)
{
    uint8_t prev[DIFF_LEN], cur[DIFF_LEN];
    char diff[10240];
    if (!rd(conn, prev, DIFF_LEN)) { plog("%s conn=%llx unreadable", tag, (unsigned long long)conn); return; }
    char key[128], lastKey[128] = "";
    for (int s = 0; s < secs * 1000 / g_period; s++) {
        Sleep(g_period);
        flushHits();
        if (drv && rq(drv + OFF_SERVERCONN) != conn) {
            if (g_bpaddr) setWatch(0);
            flushHits();
            plog("%s conn gone at %d", tag, s);
            return;
        }
        if (!rd(conn, cur, DIFF_LEN)) { plog("%s conn unreadable at %d", tag, s); return; }
        double lrt = 0;
        memcpy(&lrt, cur + OFF_CONN_LRT, 8);
        if (g_period < 100) {
            snprintf(key, sizeof key, "lrt=%.3f st=%u world=%llx", lrt, cur[OFF_CONN_STATE],
                     (unsigned long long)(drv ? rq(drv + OFF_WORLD) : 0));
            if (strcmp(key, lastKey)) { plog("%s %d %s", tag, s, key); strcpy(lastKey, key); }
            continue;
        }
        size_t o = 0;
        int more = 0;
        diff[0] = 0;
        for (int i = 0; i < DIFF_LEN; i++)
            if (cur[i] != prev[i]) {
                if (o + 16 >= sizeof diff) { more++; continue; }
                o += snprintf(diff + o, sizeof diff - o, " %x:%02x>%02x", i, prev[i], cur[i]);
            }
        plog("%s %d lrt=%.3f st=%u world=%llx drv=%llx%s%s", tag, s, lrt, cur[OFF_CONN_STATE],
             (unsigned long long)(drv ? rq(drv + OFF_WORLD) : 0), (unsigned long long)rq(conn + OFF_CONN_DRIVER), diff,
             more ? " ..." : "");
        memcpy(prev, cur, DIFF_LEN);
    }
}

/* ---- ndscan= : live drivers only; keep scanning until one holds a ServerConnection ---- */
struct ndctx { uint64_t cls, found; int pass; };

static int ndHit(uint64_t obj, void *vctx)
{
    struct ndctx *c = vctx;
    if (!isDriver(obj, c->cls)) return 0;
    uint64_t sc = rq(obj + OFF_SERVERCONN);
    plog("NDHIT pass=%d obj=%llx cls=%llx world=%llx ServerConnection=%llx clients=%u", c->pass,
         (unsigned long long)obj, (unsigned long long)rq(obj + OFF_CLASS), (unsigned long long)rq(obj + OFF_WORLD),
         (unsigned long long)sc, (unsigned)(rq(obj + OFF_CLIENTCONNS + 8) & 0xffffffff));
    if (sc) { c->found = obj; return 1; }
    return 0;
}

static void cmdNdscan(uint64_t vt, int secs, uint64_t cls)
{
    plog("NDSCAN start vt=%llx secs=%d cls=%llx", (unsigned long long)vt, secs, (unsigned long long)cls);
    struct ndctx c = { cls, 0, 0 };
    DWORD until = GetTickCount() + secs * 1000u;
    do {
        DWORD t = GetTickCount();
        int n = scanPass(vt, ndHit, &c);
        if (c.found) break;
        if (c.pass % 10 == 0)
            plog("NDSCAN pass=%d vtable matches=%d ms=%lu, no driver with a connection", c.pass, n, GetTickCount() - t);
        c.pass++;
    } while ((int)(until - GetTickCount()) > 0);
    if (!c.found) { plog("NDSCAN done, no live driver held a ServerConnection"); return; }
    uint64_t conn = rq(c.found + OFF_SERVERCONN);
    uint64_t back = rq(conn + OFF_CONN_DRIVER);
    plog("NDSCAN conn=%llx conn.Driver=%llx (%s)", (unsigned long long)conn, (unsigned long long)back,
         back == c.found ? "points back: a real connection" : "does NOT point back");
    sampleConn(conn, c.found, secs > 0 ? secs : 10, "NDSNAP");
}

/* ---- watch= : a driver whose address is already known (from Lua's NotifyOnNewObject), no scanning ---- */
static void cmdWatch(uint64_t drv, int secs)
{
    DWORD start = GetTickCount(), until = start + secs * 1000u;
    plog("WATCH drv=%llx secs=%d", (unsigned long long)drv, secs);
    uint64_t conn = 0, world = 0;
    while ((int)(until - GetTickCount()) > 0) {
        if (!rq(drv)) { plog("WATCH drv unreadable after %lums", GetTickCount() - start); return; }
        uint64_t w = rq(drv + OFF_WORLD);
        if (w != world) { plog("WATCH +%lums World=%llx", GetTickCount() - start, (unsigned long long)w); world = w; }
        conn = rq(drv + OFF_SERVERCONN);
        if (conn) break;
        Sleep(1);
    }
    if (!conn) { plog("WATCH no ServerConnection within %ds", secs); return; }
    uint64_t back = rq(conn + OFF_CONN_DRIVER);
    plog("WATCH +%lums ServerConnection=%llx vt=%llx cls=%llx conn.Driver=%llx (%s)", GetTickCount() - start,
         (unsigned long long)conn, (unsigned long long)rq(conn), (unsigned long long)rq(conn + OFF_CLASS),
         (unsigned long long)back, back == drv ? "points back" : "does NOT point back");
    if (g_bpconn) plog("WATCH write-watch on State byte %llx, %d threads", (unsigned long long)(conn + OFF_CONN_STATE),
                       setWatch(conn + OFF_CONN_STATE));
    sampleConn(conn, drv, secs, "WSNAP");
    if (g_bpaddr) setWatch(0);
    flushHits();
}

/* ---- drv= : server side ClientConnections ---- */
static void cmdDrv(uint64_t drv, int secs)
{
    if (!rq(drv)) { plog("drv=%llx unreadable", (unsigned long long)drv); return; }
    plog("DRV %llx sampling ClientConnections", (unsigned long long)drv);
    char last[1024] = "";
    for (int s = 0; s < secs * 1000 / g_period; s++) {
        uint64_t data = rq(drv + OFF_CLIENTCONNS), nm = rq(drv + OFF_CLIENTCONNS + 8);
        int num = (int)(nm & 0xffffffff), max = (int)(nm >> 32);
        char buf[1024];
        size_t o = 0;
        buf[0] = 0;
        for (int i = 0; i < num && i < 8; i++) {
            uint64_t c = rq(data + 8u * i);
            double lrt = 0;
            if (!rd(c + OFF_CONN_LRT, &lrt, 8)) { o += snprintf(buf + o, sizeof buf - o, " [c%d bad]", i); continue; }
            uint8_t st = 0;
            rd(c + OFF_CONN_STATE, &st, 1);
            o += snprintf(buf + o, sizeof buf - o, " [c%d=%llx lrt=%.3f st=%u drv=%llx]", i, (unsigned long long)c,
                          lrt, st, (unsigned long long)rq(c + OFF_CONN_DRIVER));
        }
        if (g_period >= 100 || strcmp(buf, last) || s == 0) plog("DRVSNAP %d num=%d max=%d%s", s, num, max, buf);
        strcpy(last, buf);
        Sleep(g_period);
    }
}

static void cmdRead(uint64_t addr, uint64_t len)
{
    char buf[4096];
    size_t o = 0;
    if (len > 0x800) len = 0x800;
    for (uint64_t i = 0; i + 8 <= len; i += 8) {
        uint64_t v;
        if (!rd(addr + i, &v, 8)) { plog("read=%llx+%llx unreadable", (unsigned long long)addr,
                                         (unsigned long long)i); break; }
        o += snprintf(buf + o, sizeof buf - o, "%s%llx", o ? " " : "", (unsigned long long)v);
    }
    plog("READ %llx: %s", (unsigned long long)addr, buf);
}

static void run(char *line)
{
    unsigned long long a = 0, b = 0, c = 0;
    int secs = 0;
    line[strcspn(line, "\r\n")] = 0;
    if (!*line) return;
    if (!strcmp(line, "base=1")) plog("BASE %p", (void *)GetModuleHandleA(NULL));
    else if (sscanf(line, "read=0x%llx:0x%llx", &a, &b) == 2 || sscanf(line, "read=0x%llx:%llx", &a, &b) == 2)
        cmdRead(a, b);
    else if (sscanf(line, "ndscan=0x%llx:%d:0x%llx", &a, &secs, &c) >= 1) cmdNdscan(a, secs, c);
    else if (sscanf(line, "scan=0x%llx:%d", &a, &secs) >= 1) cmdScan(a, secs);
    else if (sscanf(line, "bpconn=%d", &secs) == 1) { g_bpconn = secs; plog("BPCONN %d", secs); }
    else if (sscanf(line, "bpw=0x%llx", &a) == 1) plog("BPW %llx on %d threads", a, setWatch(a));
    else if (sscanf(line, "bpx=0x%llx", &a) == 1) {
        uint64_t at = (uint64_t)(uintptr_t)GetModuleHandleA(NULL) + a;
        plog("BPX exe+%llx (%llx) on %d threads", a, (unsigned long long)at, setWatchKind(at, 1));
    }
    else if (!strcmp(line, "bphits")) flushHits();
    else if (!strcmp(line, "bpclear")) { setWatch(0); flushHits(); plog("BP cleared, %ld hits", g_nhits); }
    else if (sscanf(line, "period=%d", &secs) == 1) { g_period = secs < 1 ? 1 : secs > 1000 ? 1000 : secs;
                                                      plog("PERIOD %dms", g_period); }
    else if (sscanf(line, "watch=0x%llx:%d", &a, &secs) >= 1) cmdWatch(a, secs ? secs : 15);
    else if (sscanf(line, "drv=0x%llx:%d", &a, &secs) >= 1) cmdDrv(a, secs ? secs : 10);
    else if (sscanf(line, "conn=0x%llx:%d", &a, &secs) >= 1) sampleConn(a, 0, secs ? secs : 10, "CONNSNAP");
    else plog("unknown command: %s", line);
}

static DWORD WINAPI worker(LPVOID arg)
{
    (void)arg;
    char cmd[MAX_PATH + 32], work[MAX_PATH + 32], line[512];
    snprintf(cmd, sizeof cmd, "%s" PREFIX "_cmd.txt", g_dir);
    snprintf(work, sizeof work, "%s" PREFIX "_cmd.work", g_dir);
    plog("vtprobe ready, base %p", (void *)GetModuleHandleA(NULL));
    for (;;) {
        Sleep(100);
        DeleteFileA(work);
        if (!MoveFileA(cmd, work)) continue;
        FILE *f = fopen(work, "rb");
        if (!f) continue;
        while (fgets(line, sizeof line, f)) run(line);
        fclose(f);
        DeleteFileA(work);
    }
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD why, LPVOID r)
{
    (void)h; (void)r;
    if (why != DLL_PROCESS_ATTACH) return TRUE;
    DWORD n = GetEnvironmentVariableA("VTH_DIR", g_dir, sizeof g_dir - 2);
    if (!n || n >= sizeof g_dir - 2) snprintf(g_dir, sizeof g_dir, "%sbridge/", PVE_ROOT);
    else if (g_dir[n - 1] != '/' && g_dir[n - 1] != '\\') strcat(g_dir, "/");
    g_buf = VirtualAlloc(NULL, CHUNK, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (g_buf) CloseHandle(CreateThread(NULL, 0, worker, NULL, 0, NULL));
    return TRUE;
}
