/*
 * pvenative.dll - native helper for the offline Marauders PvE mod.
 *
 * Loaded into the game by the Lua bridge (package.loadlib(path, "*") only runs DllMain, which starts a worker
 * thread). The thread polls bridge/native_cmd.txt and answers in bridge/native_out.txt. It exists because Lua
 * can't build a TMap: offline, USIGISInventoryComponent.InventoryContainerSizes (TMap<FString, FInventoryGridPair>)
 * is empty (the backend normally fills it), so every inventory grid has 0 cells and equipping crashes.
 *
 * The map is built by hand with memory from the engine's own allocator (GMalloc, "binned2"), so the engine can
 * free/rehash it later. It uses ONE hash bucket (HashSize=1): the chain is walked linearly, so it doesn't matter
 * what hash function the engine uses; the first Add() rehashes it with the real one.
 *
 * Offsets are for the current Steam build of RaidGame-Win64-Shipping.exe (UE 4.26); init refuses to run if the
 * allocator doesn't identify itself as "binned2".
 *
 * Commands:
 *   info                          allocator check
 *   alloctest                     Malloc(32) + write, nothing freed
 *   dumpmap <addr>                print the container-size map of the inventory component at <addr>
 *   merge <addr>                  add the default entries the map lacks
 *   fill <addr> [Name:CxR ...]    fill the map (default table below, or the given entries)
 */
#include <windows.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define GMALLOC_RVA 0x58aee70u
#define MAP_OFFSET 0x128u /* USIGISInventoryComponent::InventoryContainerSizes */
/* The project folder, with a trailing slash. native/build.sh passes it as -DPVE_ROOT="\"<folder>/\"". */
#ifndef PVE_ROOT
#define PVE_ROOT "C:/MaraudersPvE/"
#endif
#define LOG_DIR PVE_ROOT "bridge/"
#ifndef PREFIX /* files are PREFIX_cmd.txt / PREFIX_out.txt; a rebuilt copy loaded next to a locked old one needs its own */
#define PREFIX "native"
#endif

static void say(const char *fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    FILE *f = fopen(LOG_DIR PREFIX "_out.txt", "a");
    if (f) { fputs(buf, f); fputc('\n', f); fclose(f); }
}

static int readable(const void *p, size_t n) {
    MEMORY_BASIC_INFORMATION mbi;
    if (!VirtualQuery(p, &mbi, sizeof mbi)) return 0;
    if (mbi.State != MEM_COMMIT || (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD))) return 0;
    return (uintptr_t)p + n <= (uintptr_t)mbi.BaseAddress + mbi.RegionSize;
}

/* ---- engine allocator ---- */
typedef struct FMalloc FMalloc;
typedef void *(*MallocFn)(FMalloc *, size_t, uint32_t);
static FMalloc *gmalloc;

static int init_allocator(void) {
    uint8_t *base = (uint8_t *)GetModuleHandleA(NULL);
    FMalloc **slot = (FMalloc **)(base + GMALLOC_RVA);
    if (!readable(slot, 8) || !*slot) return 0;
    void **vt = *(void ***)*slot;
    if (!readable(vt, 8 * 19)) return 0;
    /* vtable[18] = GetDescriptiveName(): lea rax,[rip+x]; ret  -> L"binned2" */
    uint8_t *f = (uint8_t *)vt[18];
    if (!readable(f, 8) || f[0] != 0x48 || f[1] != 0x8d || f[2] != 0x05 || f[7] != 0xc3) return 0;
    const wchar_t *name = (const wchar_t *)(f + 7 + *(int32_t *)(f + 3));
    if (!readable(name, 16) || wcsncmp(name, L"binned2", 7) != 0) return 0;
    gmalloc = *slot;
    return 1;
}

static void *engine_malloc(size_t size, uint32_t align) {
    void **vt = *(void ***)gmalloc;
    return ((MallocFn)vt[2])(gmalloc, size, align);
}

/* ---- TMap<FString, FInventoryGridPair> (TSet of 32-byte elements, inline bit array + 1 inline hash bucket) ---- */
typedef struct {
    wchar_t *data; int32_t num, max;     /* FString */
    uint8_t col, row, pad[6];            /* FInventoryGridPair, padded to TPair's 24 bytes */
    int32_t hashNext, hashIndex;         /* TSetElement */
} Elem;

typedef struct {
    Elem *data; int32_t num, max;        /* Elements.Data (TArray) */
    uint32_t bitsInline[4]; uint32_t *bitsSecondary; int32_t numBits, maxBits;
    int32_t firstFree, numFree;
    int32_t hashInline; int32_t hashPad; int32_t *hashSecondary;
    int32_t hashSize;
} Map;

typedef struct { const char *name; int col, row; } Entry;
static const Entry DEFAULTS[] = {
    { "PocketLeft", 2, 2 }, { "PocketRight", 1, 2 }, { "Stash", 6, 15 }, { "LootCon", 6, 5 },
    { "LootPocketLeft", 1, 2 }, { "Lobby", 5, 4 }, { "Gift", 6, 15 }, { "scrap", 4, 6 }, { "Shop", 6, 10 },
    { "RigSlot1", 2, 2 }, { "RigSlot2", 2, 2 }, { "RigSlot3", 2, 2 }, { "RigSlot4", 2, 2 },
};

static void dumpmap(Map *m) {
    say("map: num=%d max=%d bits=%d/%d hashSize=%d data=%p", m->num, m->max, m->numBits, m->maxBits, m->hashSize, (void *)m->data);
    for (int i = 0; i < m->num && i < 128 && m->data && readable(m->data + i, sizeof(Elem)); i++) {
        if (!(m->bitsInline[i / 32] >> (i % 32) & 1)) continue;
        Elem *e = &m->data[i];
        char key[96] = "?";
        if (e->data && readable(e->data, 2)) {
            int k = 0;
            for (; k < 90 && e->data[k]; k++) key[k] = (char)e->data[k];
            key[k] = 0;
        }
        say("  [%d] %s = %dx%d next=%d", i, key, e->col, e->row, e->hashNext);
    }
}

static int fill(Map *m, const Entry *list, int n) {
    if (m->data || m->num || m->numBits) { say("fill: map is not empty (num=%d); not touching it", m->num); return 0; }
    if (n > 128) { say("fill: too many entries"); return 0; }
    Elem *el = (Elem *)engine_malloc((size_t)n * sizeof(Elem), 8);
    if (!el) { say("fill: Malloc failed"); return 0; }
    memset(el, 0, (size_t)n * sizeof(Elem));
    for (int i = 0; i < n; i++) {
        size_t len = strlen(list[i].name) + 1;
        wchar_t *s = (wchar_t *)engine_malloc(len * 2, 2);
        if (!s) { say("fill: Malloc failed for key"); return 0; }
        for (size_t k = 0; k < len; k++) s[k] = (wchar_t)(unsigned char)list[i].name[k];
        el[i].data = s; el[i].num = el[i].max = (int32_t)len;
        el[i].col = (uint8_t)list[i].col; el[i].row = (uint8_t)list[i].row;
        el[i].hashNext = (i + 1 < n) ? i + 1 : -1;  /* one chain through all elements */
        el[i].hashIndex = 0;
    }
    /* Publish in an order that never leaves a half-built map visible to a reader. */
    m->hashInline = 0;          /* bucket 0 -> element 0 */
    m->hashSecondary = NULL;
    m->hashSize = 1;
    memset(m->bitsInline, 0, sizeof m->bitsInline);
    for (int i = 0; i < n; i++) m->bitsInline[i / 32] |= 1u << (i % 32);
    m->bitsSecondary = NULL;
    m->numBits = n; m->maxBits = 128;
    m->firstFree = -1; m->numFree = 0;
    m->num = n; m->max = n;
    MemoryBarrier();
    m->data = el;
    say("fill: %d entries written", n);
    return 1;
}

/* Adds the entries of `list` whose key the map lacks (case-insensitive, like FString ==). The old element array and
 * hash buffer are left allocated (leaked): the engine never frees them, and the keys' buffers move to the new array. */
static int merge(Map *m, const Entry *list, int n) {
    if (m->bitsSecondary || m->maxBits > 128 || (m->num && !m->data)) { say("merge: unexpected map shape"); return 0; }
    Elem tmp[128];
    int cnt = 0;
    for (int i = 0; i < m->num && i < 128; i++) {
        if (!(m->bitsInline[i / 32] >> (i % 32) & 1)) continue;
        if (!readable(m->data + i, sizeof(Elem))) { say("merge: unreadable element %d", i); return 0; }
        tmp[cnt++] = m->data[i];
    }
    int added = 0;
    for (int j = 0; j < n && cnt < 128; j++) {
        int have = 0;
        for (int i = 0; i < cnt; i++) {
            if (tmp[i].data && readable(tmp[i].data, 2)) {
                char key[96]; int k = 0;
                for (; k < 90 && tmp[i].data[k]; k++) key[k] = (char)tmp[i].data[k];
                key[k] = 0;
                if (!_stricmp(key, list[j].name)) { have = 1; break; }
            }
        }
        if (have) continue;
        size_t len = strlen(list[j].name) + 1;
        wchar_t *s = (wchar_t *)engine_malloc(len * 2, 2);
        if (!s) { say("merge: Malloc failed"); return 0; }
        for (size_t k = 0; k < len; k++) s[k] = (wchar_t)(unsigned char)list[j].name[k];
        memset(&tmp[cnt], 0, sizeof(Elem));
        tmp[cnt].data = s; tmp[cnt].num = tmp[cnt].max = (int32_t)len;
        tmp[cnt].col = (uint8_t)list[j].col; tmp[cnt].row = (uint8_t)list[j].row;
        cnt++; added++;
    }
    if (!added) { say("merge: nothing to add"); return 1; }
    Elem *el = (Elem *)engine_malloc((size_t)cnt * sizeof(Elem), 8);
    if (!el) { say("merge: Malloc failed"); return 0; }
    for (int i = 0; i < cnt; i++) {
        el[i] = tmp[i];
        el[i].hashNext = (i + 1 < cnt) ? i + 1 : -1;
        el[i].hashIndex = 0;
    }
    m->hashInline = 0; m->hashSecondary = NULL; m->hashSize = 1;
    memset(m->bitsInline, 0, sizeof m->bitsInline);
    for (int i = 0; i < cnt; i++) m->bitsInline[i / 32] |= 1u << (i % 32);
    m->numBits = cnt; m->maxBits = 128;
    m->firstFree = -1; m->numFree = 0;
    m->num = cnt; m->max = cnt;
    MemoryBarrier();
    m->data = el;
    say("merge: added %d entries (%d total)", added, cnt);
    return 1;
}

static void run(char *line) {
    char *save = NULL, *verb = strtok_s(line, " \t\r\n", &save);
    if (!verb) return;
    say("> %s", verb);
    if (!strcmp(verb, "info")) {
        say("allocator ok=%d gmalloc=%p", gmalloc != NULL, (void *)gmalloc);
    } else if (!strcmp(verb, "alloctest")) {
        uint64_t *p = (uint64_t *)engine_malloc(32, 8);
        if (p) { p[0] = 0x1122334455667788ull; p[3] = p[0]; }
        say("alloctest: %p (leaked on purpose)", (void *)p);
    } else if (!strcmp(verb, "dumpmap") || !strcmp(verb, "fill") || !strcmp(verb, "merge")) {
        char *a = strtok_s(NULL, " \t\r\n", &save);
        if (!a) { say("needs an address"); return; }
        uint8_t *comp = (uint8_t *)(uintptr_t)strtoull(a, NULL, 0);
        if (!readable(comp, MAP_OFFSET + sizeof(Map))) { say("bad address %s", a); return; }
        Map *m = (Map *)(comp + MAP_OFFSET);
        if (!strcmp(verb, "dumpmap")) { dumpmap(m); return; }
        if (!strcmp(verb, "merge")) { merge(m, DEFAULTS, (int)(sizeof DEFAULTS / sizeof DEFAULTS[0])); dumpmap(m); return; }
        Entry custom[64];
        int n = 0;
        for (char *t; n < 64 && (t = strtok_s(NULL, " \t\r\n", &save)); ) {
            char *colon = strchr(t, ':');
            int c, r;
            if (colon && sscanf(colon + 1, "%dx%d", &c, &r) == 2) {
                *colon = 0;
                custom[n].name = _strdup(t); custom[n].col = c; custom[n].row = r; n++;
            }
        }
        if (n) fill(m, custom, n); else fill(m, DEFAULTS, (int)(sizeof DEFAULTS / sizeof DEFAULTS[0]));
        dumpmap(m);
    } else say("unknown command %s", verb);
}

static DWORD WINAPI worker(LPVOID arg) {
    (void)arg;
    say("pvenative: worker started, allocator %s", init_allocator() ? "OK (binned2)" : "NOT FOUND - fill disabled");
    for (;;) {
        Sleep(200);
        const char *cmd = LOG_DIR PREFIX "_cmd.txt", *work = LOG_DIR PREFIX "_cmd.work";
        remove(work);
        if (rename(cmd, work) != 0) continue;
        FILE *f = fopen(work, "r");
        if (!f) continue;
        char line[512];
        while (fgets(line, sizeof line, f)) {
            if (!gmalloc && strncmp(line, "info", 4) && strncmp(line, "dumpmap", 7)) { say("allocator not available"); continue; }
            run(line);
        }
        fclose(f);
        remove(work);
    }
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD why, LPVOID r) {
    (void)r;
    if (why == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(h);
        CreateThread(NULL, 0, worker, NULL, 0, NULL);
    }
    return TRUE;
}
