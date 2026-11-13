/*
 * pvepatch.dll: offline-only code patches, applied in memory when the PvEDirector loads this DLL
 * (package.loadlib(path, "*") runs DllMain). Nothing on disk changes. Each patch checks the original bytes
 * first and is skipped (and reported) if they differ, e.g. after a game update.
 *
 * Why: the shipped client only ever runs as a network client of a dedicated server. Standalone, the player's
 * weapon is the Authority, and these role checks then skip work a live server or client would do:
 *   - FireWeapon (ARaidWeapon vtable +0x7d0) sends ServerTraceFireProjectile / ServerFireProjectile only when
 *     Role < Authority. The server half applies the damage, so offline shots never hurt anything.
 *     With the check gone the RPC runs locally (standalone calls are Local) with the client's real trace.
 *   - SimulateWeaponFire (vtable +0x7c0) returns at once for an Authority weapon (dedicated servers skip
 *     cosmetics): no muzzle flash, fire sound, camera shake or fire anim, for the player or bots.
 *   - Bot death bodies get no mesh or pose (server-only setup is a stub here); see hookBody.
 *   - The SIGIS loot handlers (Client_*AddLootItem*) skip creating the client's item copies when standalone,
 *     so opened containers showed an empty grid.
 * Results go to bridge/patch_out.txt.
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>

typedef struct { const char *name; DWORD rva; unsigned char old[8], new_[8]; int len; } Patch;

static const Patch PATCHES[] = {
    /* cmp byte [rdi+0xF0],3 ; jae +0x16d  (trace-fire guns: ServerTraceFireProjectile) */
    { "FireWeapon trace RPC", 0x1885c1a, { 0x0f, 0x83, 0x6d, 0x01, 0x00, 0x00 }, { 0x66, 0x0f, 0x1f, 0x44, 0x00, 0x00 }, 6 },
    /* cmp byte [rdi+0xF0],3 ; jae +0x28   (projectile guns: ServerFireProjectile) */
    { "FireWeapon projectile RPC", 0x1885d63, { 0x73, 0x28 }, { 0x66, 0x90 }, 2 },
    /* cmp byte [rcx+0xF0],3 ; je return   (SimulateWeaponFire cosmetics) */
    { "SimulateWeaponFire effects", 0x189a4a3, { 0x0f, 0x84, 0x04, 0x04, 0x00, 0x00 }, { 0x66, 0x0f, 0x1f, 0x44, 0x00, 0x00 }, 6 },
    /* cmp dword [rbx+0x26c],r15d ; jle no-recoil  in the weapon's per-tick recoil (0x189f890). +0x26c is the
       client's copy of the clip count, written only when Role < Authority (0x188c27f, 0x189c100), so offline it
       stays 0 and aim recoil never applied (the kick itself only applies while aiming down sights, by design). */
    { "Weapon recoil ammo gate", 0x189f99a, { 0x0f, 0x8e, 0xcf, 0x02, 0x00, 0x00 }, { 0x66, 0x0f, 0x1f, 0x44, 0x00, 0x00 }, 6 },
    /* call GetNetMode ; cmp eax,3 ; jne return  at the top of the client hit simulation (0x18a1c70, called from
       FireWeapon): only NM_Client spawned bullet impacts (pooled RaidPoolImpactEffect FX/sound/decal), hit reacts. */
    { "Bullet impact effects", 0x18a1ca7, { 0x0f, 0x85, 0x54, 0x08, 0x00, 0x00 }, { 0x66, 0x0f, 0x1f, 0x44, 0x00, 0x00 }, 6 },
    /* same NM_Client gate in the projectile hit simulation (0x189bc80, from RaidProjectile OnRealImpact/OnRealAnyHit) */
    { "Projectile impact effects", 0x189bcbc, { 0x0f, 0x85, 0x9b, 0x02, 0x00, 0x00 }, { 0x66, 0x0f, 0x1f, 0x44, 0x00, 0x00 }, 6 },
    /* cmp eax,3 ; jne skip  in RaidWeapon_Instant / its subclass "simulate instant hit" (vtable +0x850, 0x189b340 and
       0x189b800; base RaidWeapon's slot is an empty stub): melee/instant hits only ran OnProxyHitReact on a client. */
    { "Instant-hit react (Instant)", 0x189b74c, { 0x75, 0x79 }, { 0x66, 0x90 }, 2 },
    { "Instant-hit react (subclass)", 0x189bbdf, { 0x75, 0x6f }, { 0x66, 0x90 }, 2 },
    /* cmp byte [rbx+0xF0],3 ; je return  in RaidPlayerController::EnterEvacRaidVolume (0x182c210, called by the
       EscapeZoneSpaceGate Blueprint on overlap): only a client went on to EvacRaid + Server_EnterEvacRaidVolume, so
       offline a pod or ship flying into the space gate did nothing. */
    { "Space gate extraction", 0x182c23e, { 0x0f, 0x84, 0xe4, 0x00, 0x00, 0x00 }, { 0x66, 0x0f, 0x1f, 0x44, 0x00, 0x00 }, 6 },
    /* cmp byte [rcx+0xF0],3 ; je return  in RaidCharacter::NetMultiVault (0x180c620): an Authority character never
       played PlayVaultAnimations / PlayClimbAnimations, so offline nobody did. */
    { "Vault/climb animations", 0x180c648, { 0x0f, 0x84, 0xa1, 0x01, 0x00, 0x00 }, { 0x66, 0x0f, 0x1f, 0x44, 0x00, 0x00 }, 6 },
    /* call IsStandalone (0x316ebe0: GetNetMode() == NM_Standalone) ; test al,al ; jne skip-NewObject
       in the SIGIS inventory's loot handlers: a client creates its own copy of each looted item (into LootsItems,
       where the loot panel looks items up by GUID); standalone skipped that, so containers opened empty. */
    { "Loot item copy (Client_AddLootItemStruct)", 0x97e3ba, { 0x0f, 0x85, 0xee, 0x00, 0x00, 0x00 }, { 0x66, 0x0f, 0x1f, 0x44, 0x00, 0x00 }, 6 },
    { "Loot item copy (Client_AddLootItem)", 0x97e5ba, { 0x0f, 0x85, 0xf0, 0x00, 0x00, 0x00 }, { 0x66, 0x0f, 0x1f, 0x44, 0x00, 0x00 }, 6 },
    { "Loot item copy (Client_AddLootItemsStruct)", 0x97e918, { 0x0f, 0x85, 0xc8, 0x00, 0x00, 0x00 }, { 0x66, 0x0f, 0x1f, 0x44, 0x00, 0x00 }, 6 },
    { "Loot item copy (Client_BatchAddLootItems)", 0x97f5aa, { 0x0f, 0x85, 0xe7, 0x00, 0x00, 0x00 }, { 0x66, 0x0f, 0x1f, 0x44, 0x00, 0x00 }, 6 },
    /* Bot death, after the body setup (see botBody): keep the dead pawn visible and alive until its body is posed.
       call [rax+0x5a0] on the mesh, call [rax+0x300] (hide actor), movss xmm1, 0.2 -> xorps xmm1,xmm1 (SetLifeSpan 0) */
    { "Bot death: keep mesh visible", 0x17ee057, { 0xff, 0x90, 0xa0, 0x05, 0x00, 0x00 }, { 0x66, 0x0f, 0x1f, 0x44, 0x00, 0x00 }, 6 },
    { "Bot death: keep pawn shown", 0x17ee065, { 0xff, 0x90, 0x00, 0x03, 0x00, 0x00 }, { 0x66, 0x0f, 0x1f, 0x44, 0x00, 0x00 }, 6 },
    /* The death body setup (0x17edf20) runs from a 2.8 s timer set at the death (0x1819d00), meant to wait out the
       server's death animation. Bots ragdoll offline and settle in under a second: movss xmm3, [2.8f] -> [1.0f]
       (the 1.0 at 0x4043cb0 that the other death path, 0x1806760, already uses). */
    { "Bot death: body after 1.0 s", 0x1819ddb, { 0xf3, 0x0f, 0x10, 0x1d, 0x4d, 0xdb, 0xd8, 0x02 }, { 0xf3, 0x0f, 0x10, 0x1d, 0xcd, 0x9e, 0x82, 0x02 }, 8 },
    { "Bot death: no 0.2 s lifespan", 0x17ee071, { 0xf3, 0x0f, 0x10, 0x0d, 0x7b, 0x16, 0x8a, 0x02 }, { 0x0f, 0x57, 0xc9, 0x0f, 0x1f, 0x44, 0x00, 0x00 }, 8 },
    /* The same for the raiders' own death (0x17ee0a0, see below): mov rax,[rbx] -> jmp over the gear setup (poseBody
       does it), movss xmm1, 0.2 -> xorps xmm1,xmm1 (SetLifeSpan 0). */
    { "Raider death: gear later", 0x17ee1d4, { 0x48, 0x8b, 0x03 }, { 0xeb, 0x5e, 0x90 }, 3 },
    { "Raider death: no 0.2 s lifespan", 0x17ee2a2, { 0xf3, 0x0f, 0x10, 0x0d, 0x32, 0xd1, 0xda, 0x02 }, { 0x0f, 0x57, 0xc9, 0x0f, 0x1f, 0x44, 0x00, 0x00 }, 8 },
};

/*
 * Bot bodies. ARaidBot's death (vtable +0xcc0, 0x17edf20) spawns its DefaultDeathBody container, moves the loot into
 * it, then hides the pawn and gives it 0.2 s to live. The step that gives the container the body's meshes and pose is
 * server code, compiled to an empty stub (0x7e0290) in this client, so the container stayed hidden and empty-looking:
 * bodies vanished and couldn't be looted. The player's death (0x1842800) uses the intact routine for this
 * (ASIGISDeathActor setup 0x8fac80, then the equipment one 0x8fac00). With a live pose component it takes the
 * standalone branch (0x8ef3c0): both pose meshes get the meshes and CopyPoseFromSkeletalComponent; it needs a head
 * mesh, and bots have one combined mesh, so the bot mesh goes in both and the head poser is emptied after.
 * The pose at the moment of death is the standing animation, so the stub call only queues the bot; the director
 * ragdolls it (it stays shown and alive, see the patches above) and calls pve_bodies every frame, which poses and
 * shows each body once the director says the ragdoll has settled (BOT_SETTLED), then RETIRE_DELAY_MS after that hides
 * the pawn and gives it the original 0.2 s.
 *
 * Raiders (GOAPNodeBot_*: every placed station NPC, their copies and all rivals) don't use that routine: their vtable
 * +0xcc0 is 0x17ee0a0, written for a head + body pawn, with an intact pose call (0x8fac80 with Mesh, here a mask or
 * head, and the body component at +0xce0). It ran on the 1.0 s timer, mid-collapse, then gave the pawn 0.2 s: corpses
 * froze half fallen. That call is queued here the same way.
 */
#define BOT_BODY_CALL  0x17ee028   /* call 0x7e0290 (death actor, SkeletalMesh, mesh component); rbx = the bot */
#define BODY_STUB      0x7e0290
#define DEATH_SET_BODY 0x8fac80    /* (death, body mesh, pose component, head mesh, body component) */
#define DEATH_SET_GEAR 0x8fac00    /* (death, chest mesh, helmet mesh, bag mesh, FString *guild badge) */
#define CHAR_GET_GEAR  0xcb8       /* ARaidCharacter vtable: (this, &helmet, &chest, &bag) */
#define SET_SKEL_MESH  0x8c8       /* USkinnedMeshComponent vtable: SetSkeletalMesh(mesh, bReinitPose) */
#define MESH_HIDE      0x5a0       /* what the death code calls on the pawn's mesh with false */
#define ACTOR_HIDE     0x300       /* AActor vtable: SetActorHiddenInGame */
#define ACTOR_LIFESPAN 0x398       /* AActor vtable: SetLifeSpan */
#define DEATH_HEADPOSE 0x5a8       /* ASIGISDeathActor.HeadPose */
#define RAIDER_BODY_CALL 0x17ee1cf /* call 0x8fac80 in 0x17ee0a0; rbx = the bot */
#define BOT_SETTLED    0xcd0       /* ARaidBot.AiMissRange: unused once dead; main.lua settleRagdolls writes SETTLED_MARK */
#define SETTLED_MARK   -12345.0f
#define BOT_LOOT       0xbf0       /* ARaidBot.BotLootItems */
#define SETTLE_MAX_MS  7000    /* after the setup call: pose anyway (main.lua gives up first; this covers a failed ragdoll) */
#define RETIRE_DELAY_MS 35     /* body shown -> ragdoll hidden (~3 frames: the pose meshes need to draw first) */
#define UFUNCTION_SCRIPT 0x60 /* TArray<uint8> Script: bytecode, count */
#define STALE_MS       20000   /* queued this long: pve_bodies wasn't called (map change?), the objects may be gone */

typedef struct { void *data; int num, max; } FStr;
typedef struct { void *data; int num, max; } FArr;
typedef void (*SetBodyFn)(void *, void *, void *, void *, void *);
typedef void (*SetGearFn)(void *, void *, void *, void *, FStr *);
typedef void (*GetGearFn)(void *, void **, void **, void **);
typedef void (*PtrBoolFn)(void *, void *, char);
typedef void (*BoolFn)(void *, char);
typedef void (*FloatFn)(void *, float);
static unsigned char *g_base;

typedef struct { void *death, *mesh, *meshComp, *head, *headComp, *bot; ULONGLONG at; int stage; } DeadBot; /* stage: 0 queued, 1 posed, 2 shown */
static DeadBot g_dead[64];
static int g_numDead;

#define VFN(obj, off) ((*(void ***)(obj))[(off) / 8])

static void queueBody(void *death, void *mesh, void *meshComp, void *head, void *headComp, void *bot) {
    if (g_numDead == (int)(sizeof g_dead / sizeof g_dead[0])) return;
    DeadBot d = { death, mesh, meshComp, head, headComp, bot, GetTickCount64(), 0 };
    g_dead[g_numDead++] = d;
}

/* Soldiers: one combined mesh, used as both body and head. */
static void botBody(void *death, void *mesh, void *meshComp, void *bot) {
    queueBody(death, mesh, meshComp, mesh, meshComp, bot);
}

static void poseBody(const DeadBot *d) {
    ((SetBodyFn)(g_base + DEATH_SET_BODY))(d->death, d->mesh, d->meshComp, d->head, d->headComp);
    void *headPose = *(void **)((char *)d->death + DEATH_HEADPOSE);
    if (headPose && d->head == d->mesh) ((PtrBoolFn)VFN(headPose, SET_SKEL_MESH))(headPose, NULL, 1);
    void *helmet = NULL, *chest = NULL, *bag = NULL;
    ((GetGearFn)VFN(d->bot, CHAR_GET_GEAR))(d->bot, &helmet, &chest, &bag);
    FStr badge = { 0 };
    ((SetGearFn)(g_base + DEATH_SET_GEAR))(d->death, chest, helmet, bag, &badge);
}

/* The frame after posing (the pose meshes' first frame is a few units off), over the ragdoll in the same pose. The
   game only showed it when the pawn was destroyed, 0.2 s after hiding it: the body vanished for ~20 frames. */
static void showBody(const DeadBot *d) {
    ((BoolFn)VFN(d->death, ACTOR_HIDE))(d->death, 0);
}

/* A few frames after the body is shown (its pose meshes have drawn by then): hide the ragdoll for good. */
static void retireBot(const DeadBot *d) {
    ((BoolFn)VFN(d->meshComp, MESH_HIDE))(d->meshComp, 0);
    ((BoolFn)VFN(d->bot, ACTOR_HIDE))(d->bot, 1);
    ((FloatFn)VFN(d->bot, ACTOR_LIFESPAN))(d->bot, 0.2f);
}

/* Lua: package.loadlib(dll, "pve_bodies") gives a function to call every frame on the game thread; it takes and
   returns nothing (this DLL has no Lua API to link against). */
__declspec(dllexport) int pve_bodies(void *L) {
    (void)L;
    ULONGLONG now = GetTickCount64();
    int keep = 0;
    for (int i = 0; i < g_numDead; i++) {
        ULONGLONG age = now - g_dead[i].at;
        if (age >= STALE_MS) continue;
        DeadBot *d = &g_dead[i];
        if (d->stage == 0 && (age >= SETTLE_MAX_MS || *(float *)((char *)d->bot + BOT_SETTLED) == SETTLED_MARK)) {
            poseBody(d);
            d->stage = 1;
        }
        else if (d->stage == 1) { showBody(d); d->stage = 2; d->at = now; }
        else if (d->stage == 2 && age >= RETIRE_DELAY_MS) { retireBot(d); continue; }
        g_dead[keep++] = g_dead[i];
    }
    g_numDead = keep;
    return 0;
}

/* A Lua 5.4 lua_State / CallInfo, as far as reading a C function's arguments goes (UE4SS exports no Lua API): integer
   argument i of n, or 0 if the call doesn't look like that. */
#define LUA_TOP      0x10  /* lua_State.top */
#define LUA_CI       0x20  /* lua_State.ci; its first field is the called function's stack slot */
#define LUA_SLOT     16    /* sizeof(StackValue): value (8 bytes), then the type tag */
#define LUA_VNUMINT  3

static long long intArg(void *L, int i, int n) {
    char *func = **(char ***)((char *)L + LUA_CI), *top = *(char **)((char *)L + LUA_TOP);
    if ((top - func) / LUA_SLOT != n + 1 || func[i * LUA_SLOT + 8] != LUA_VNUMINT) return 0;
    return *(long long *)(func + i * LUA_SLOT);
}

/* Lua: pve_bp_jump(UFunction address, offset): turns the JumpIfNot at that bytecode offset, the one right after a
   `<CallMath fn>(self)`, into a plain Jump: Blueprint branches on a check that's always the wrong way offline. Same
   size, same target. Anything else at that offset (a game update) is left alone. */
__declspec(dllexport) int pve_bp_jump(void *L) {
    char *fn = (char *)intArg(L, 1, 2);
    long long at = intArg(L, 2, 2);
    if (!fn) return 0;
    unsigned char *code = *(unsigned char **)(fn + UFUNCTION_SCRIPT);
    int num = *(int *)(fn + UFUNCTION_SCRIPT + 8);
    if (!code || at < 11 || at + 5 > num) return 0;
    if (code[at - 11] == 0x68 && code[at - 2] == 0x17 && code[at - 1] == 0x16 && code[at] == 0x07) code[at] = 0x06;
    return 0;
}

/* Lua: pve_bp_stub_return(UFunction address): makes a Blueprint event stub return at once. Only an 18-byte stub
   `LocalFinalFunction ExecuteUbergraph(IntConst entry) EndParms; Return Nothing; EndOfScript` is touched: its first two
   bytes become `Return Nothing` (same size; the rest is never reached). Anything else (a game update) is left alone.
   Used on the PGOS friends view's StartGetFriends: a looping 1 s native timer calls it, and it walks the whole Steam
   friends list with blocking Steam IPC on the game thread (~70 ms): a hitch every second, menu and raids alike. */
__declspec(dllexport) int pve_bp_stub_return(void *L) {
    char *fn = (char *)intArg(L, 1, 1);
    if (!fn) return 0;
    unsigned char *code = *(unsigned char **)(fn + UFUNCTION_SCRIPT);
    int num = *(int *)(fn + UFUNCTION_SCRIPT + 8);
    if (!code || num != 18) return 0;
    if (code[0] == 0x46 && code[9] == 0x1d && code[14] == 0x16 && code[15] == 0x04 && code[16] == 0x0b && code[17] == 0x53) {
        code[0] = 0x04;
        code[1] = 0x0b;
    }
    return 0;
}

/* Lua, when a map loads: forget queued bots (their objects belonged to the old world). */
__declspec(dllexport) int pve_bodies_reset(void *L) {
    (void)L;
    g_numDead = 0;
    return 0;
}

/* Redirects the call at rva (to target) through a jump stub within rel32 reach of the game: code, then
   mov rax, fn ; jmp rax. A call that's already redirected only gets fn updated (live testing with renamed DLLs). */
static const char *hookBody(unsigned char *base, DWORD rva, DWORD target, const unsigned char *code, int len, void *fn) {
    unsigned char *at = base + rva;
    int rel = (int)(target - (rva + 5));
    unsigned char old[5] = { 0xe8 };
    memcpy(old + 1, &rel, 4);
    if (memcmp(at, old, 5)) {
        unsigned char *cur = at[0] == 0xe8 ? at + 5 + *(int *)(at + 1) : NULL;
        if (!cur || memcmp(cur, code, len)) return "SKIPPED: unexpected bytes (game updated?)";
        memcpy(cur + len + 2, &fn, 8);
        FlushInstructionCache(GetCurrentProcess(), cur, len + 12);
        return "already applied (stub re-pointed to this DLL)";
    }
    unsigned char *stub = NULL;
    for (unsigned char *p = (unsigned char *)(((ULONG_PTR)base - 0x10000) & ~(ULONG_PTR)0xffff); !stub && base - p < 0x70000000; p -= 0x10000)
        stub = VirtualAlloc(p, 0x1000, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE);
    if (!stub) return "SKIPPED: no memory near the game for the stub";
    const unsigned char tail[] = { 0x48, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xe0 };
    memcpy(stub, code, len);
    memcpy(stub + len, tail, sizeof tail);
    memcpy(stub + len + 2, &fn, 8);
    FlushInstructionCache(GetCurrentProcess(), stub, len + sizeof tail);
    unsigned char call[5] = { 0xe8 };
    rel = (int)(stub - (at + 5));
    memcpy(call + 1, &rel, 4);
    DWORD prot;
    if (!VirtualProtect(at, 5, PAGE_EXECUTE_READWRITE, &prot)) return "SKIPPED: VirtualProtect failed";
    memcpy(at, call, 5);
    VirtualProtect(at, 5, prot, &prot);
    FlushInstructionCache(GetCurrentProcess(), at, 5);
    return "applied";
}

/* Bot-on-bot hits taken as self-damage. RaidGameMode::ModifyDamage (vtable +0x940, 0x17e1870) scales a hit by
   DamageSelfScale (0.3) when the instigator's PlayerState is the victim's: cmp rbx,rdi ; jne +8 ; mulss xmm6,[rsi+0x4fc].
   Bots have no PlayerState, so between two bots both are null and every bullet did 0.3 of its damage before the
   victim's armour (a flat amount per hit) took its share: 24 -> 7.2 -> 3.3 through a vest. The compare becomes a call
   to a stub that returns to the mulss only for a real (non-null) shared PlayerState, else past it. */
#define SELF_SCALE_CMP 0x17e194a
static const char *selfScaleFix(unsigned char *base) {
    static const unsigned char old[] = { 0x48, 0x3b, 0xdf, 0x75, 0x08 };
    static const unsigned char code[] = {
        0x48, 0x3b, 0xdf,             /* cmp rbx, rdi */
        0x75, 0x06,                   /* jne skip */
        0x48, 0x85, 0xdb,             /* test rbx, rbx */
        0x74, 0x01,                   /* je skip */
        0xc3,                         /* ret: on to the mulss */
        0x48, 0x83, 0x04, 0x24, 0x08, /* skip: add qword [rsp], 8 (past the 8-byte mulss) */
        0xc3 };
    unsigned char *at = base + SELF_SCALE_CMP;
    if (at[0] == 0xe8 && !memcmp(at + 5 + *(int *)(at + 1), code, sizeof code)) return "already applied";
    if (memcmp(at, old, sizeof old)) return "SKIPPED: unexpected bytes (game updated?)";
    unsigned char *stub = NULL;
    for (unsigned char *p = (unsigned char *)(((ULONG_PTR)base - 0x10000) & ~(ULONG_PTR)0xffff); !stub && base - p < 0x70000000; p -= 0x10000)
        stub = VirtualAlloc(p, 0x1000, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE);
    if (!stub) return "SKIPPED: no memory near the game for the stub";
    memcpy(stub, code, sizeof code);
    FlushInstructionCache(GetCurrentProcess(), stub, sizeof code);
    unsigned char call[5] = { 0xe8 };
    int rel = (int)(stub - (at + 5));
    memcpy(call + 1, &rel, 4);
    DWORD prot;
    if (!VirtualProtect(at, 5, PAGE_EXECUTE_READWRITE, &prot)) return "SKIPPED: VirtualProtect failed";
    memcpy(at, call, 5);
    VirtualProtect(at, 5, prot, &prot);
    FlushInstructionCache(GetCurrentProcess(), at, 5);
    return "applied";
}

/* Reports go to <project>\bridge\: this DLL is <project>\native\pvepatch.dll. */
static char bridge[MAX_PATH];
static FILE *report(const char *name, const char *mode) {
    char path[MAX_PATH]; snprintf(path, sizeof path, "%s%s", bridge, name);
    return fopen(path, mode);
}

static void apply(void) {
    FILE *f = report("patch_out.txt", "w");
    unsigned char *base = (unsigned char *)GetModuleHandleA(NULL);
    g_base = base;
    int ok = 0, n = (int)(sizeof PATCHES / sizeof PATCHES[0]);
    for (int i = 0; i < n; i++) {
        const Patch *p = &PATCHES[i];
        unsigned char *at = base + p->rva;
        const char *what;
        if (!memcmp(at, p->new_, p->len)) { what = "already applied"; ok++; }
        else if (memcmp(at, p->old, p->len)) what = "SKIPPED: unexpected bytes (game updated?)";
        else {
            DWORD prot;
            if (!VirtualProtect(at, p->len, PAGE_EXECUTE_READWRITE, &prot)) what = "SKIPPED: VirtualProtect failed";
            else {
                memcpy(at, p->new_, p->len);
                VirtualProtect(at, p->len, prot, &prot);
                FlushInstructionCache(GetCurrentProcess(), at, p->len);
                what = "applied"; ok++;
            }
        }
        if (f) fprintf(f, "%s @ +0x%lx: %s\n", p->name, (unsigned long)p->rva, what);
    }
    static const unsigned char botArg[] = { 0x49, 0x89, 0xd9 };               /* mov r9, rbx */
    static const unsigned char raiderArg[] = { 0x48, 0x89, 0x5c, 0x24, 0x30 }; /* mov [rsp+0x30], rbx (6th argument) */
    const char *body = hookBody(base, BOT_BODY_CALL, BODY_STUB, botArg, sizeof botArg, (void *)botBody);
    if (f) fprintf(f, "Bot death body setup @ +0x%x: %s\n", BOT_BODY_CALL, body);
    body = hookBody(base, RAIDER_BODY_CALL, DEATH_SET_BODY, raiderArg, sizeof raiderArg, (void *)queueBody);
    if (f) fprintf(f, "Raider death body setup @ +0x%x: %s\n", RAIDER_BODY_CALL, body);
    if (f) fprintf(f, "Bot-on-bot self-damage scale @ +0x%x: %s\n", SELF_SCALE_CMP, selfScaleFix(base));
    if (f) { fprintf(f, "%d/%d ok\n", ok, n); fclose(f); }
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD why, LPVOID r) {
    (void)r;
    if (why == DLL_PROCESS_ATTACH) {
        GetModuleFileNameA(h, bridge, sizeof bridge - 8);
        for (char *c = bridge; *c; c++) if (*c == '/') *c = '\\'; /* package.loadlib was given a / path */
        for (int up = 0; up < 2; up++) { char *s = strrchr(bridge, '\\'); if (s) s[up ? 1 : 0] = 0; }
        strcat(bridge, "bridge\\");
        apply();
    }
    return TRUE;
}

/* Lua: pve_roll_kit(bot, item table, gun, pistol, helmet, armour, bag): gives a bot the rows a level designer would set
   (FNames as comparison indices, 0 = none; UE4SS can't write row-handle structs) and runs the game's own kit spawn for
   them (BOT_KIT_SPAWN, the step placed bots go through). */
#define BOT_KIT_SPAWN  0x17cae70
#define BOT_WEAPON_ROW 0xc10
#define BOT_PISTOL_ROW 0xc20
#define BOT_HELMET_ROW 0xc40
#define BOT_ARMOUR_ROW 0xc50
#define BOT_BAG_ROW    0xc60

static void setRow(char *bot, int off, long long table, long long row) {
    *(long long *)(bot + off) = row ? table : 0;
    *(long long *)(bot + off + 8) = row; /* FName: comparison index, number 0 */
}

__declspec(dllexport) int pve_roll_kit(void *L) {
    char *bot = (char *)intArg(L, 1, 7);
    long long table = intArg(L, 2, 7);
    if (!bot || !table) return 0;
    long long gun = intArg(L, 3, 7), pistol = intArg(L, 4, 7), helmet = intArg(L, 5, 7), armour = intArg(L, 6, 7), bag = intArg(L, 7, 7);
    setRow(bot, BOT_WEAPON_ROW, table, gun);
    setRow(bot, BOT_PISTOL_ROW, table, pistol);
    setRow(bot, BOT_HELMET_ROW, table, helmet);
    setRow(bot, BOT_ARMOUR_ROW, table, armour);
    setRow(bot, BOT_BAG_ROW, table, bag);
    ((void (*)(void *))((char *)GetModuleHandleA(NULL) + BOT_KIT_SPAWN))(bot);
    return 0;
}

/* Lua: pve_add_item(bot, row, stack): adds a row to a bot's loot the way the kit step's random loot does. */
#define BOT_ADD_ITEM   0x17ee690  /* (bot, FName row, stack, condition, byte slot) */
#define LOOT_SLOT      0xc

__declspec(dllexport) int pve_add_item(void *L) {
    char *bot = (char *)intArg(L, 1, 3);
    long long row = intArg(L, 2, 3), stack = intArg(L, 3, 3);
    if (!bot || !row || stack <= 0) return 0;
    ((void (*)(void *, long long, int, int, unsigned char))((char *)GetModuleHandleA(NULL) + BOT_ADD_ITEM))(bot, row, (int)stack, 1, LOOT_SLOT);
    return 0;
}

/* Lua: pve_loose_assets(): lets the game load cooked assets from loose files (the female outfits), offline only. A shipping
   build refuses .uasset and friends outside a pak: FPakPlatformFile keeps them in ExcludedNonPakExtensions, and a pak of
   our own would need a signature. Emptying that set takes one integer: an empty TSet finds nothing. */
#define PLATFORM_FILE_GET  0x1962520  /* FPlatformFileManager::Get */
#define PLATFORM_FILE_FIND 0x1961640  /* FPlatformFileManager::FindPlatformFile(name) */
#define PAK_EXCLUDED_NUM   0x68       /* FPakPlatformFile.ExcludedNonPakExtensions: the elements array's Num */

__declspec(dllexport) int pve_loose_assets(void *L) {
    (void)L;
    char *base = (char *)GetModuleHandleA(NULL);
    void *mgr = ((void *(*)(void))(base + PLATFORM_FILE_GET))();
    char *pak = mgr ? ((char *(*)(void *, const wchar_t *))(base + PLATFORM_FILE_FIND))(mgr, L"PakFile") : NULL;
    FILE *f = report("loose_out.txt", "w");
    if (pak) {
        int *num = (int *)(pak + PAK_EXCLUDED_NUM);
        if (f) fprintf(f, "excluded extensions: %d\n", *num);
        if (*num > 0 && *num < 32) *num = 0;
    } else if (f) fprintf(f, "no pak platform file\n");
    if (f) fclose(f);
    return 0;
}


/* Lua: pve_load(path as an FName comparison index): loads an asset the cooked asset registry doesn't know, the loose outfits,
   the way a soft reference does (UKismetSystemLibrary::LoadAsset_Blocking, by a TSoftObjectPtr). UE4SS LoadAsset only sees
   the registry. */
#define LOAD_ASSET_BLOCKING 0x3172480
typedef struct { int index, serial, tag, pad; long long path; void *sub; int subNum, subMax; } SoftPtr;

__declspec(dllexport) int pve_load(void *L) {
    long long path = intArg(L, 1, 1);
    if (!path) return 0;
    SoftPtr s = { -1, 0, 0, 0, path, NULL, 0, 0 };
    ((void *(*)(SoftPtr *))((char *)GetModuleHandleA(NULL) + LOAD_ASSET_BLOCKING))(&s);
    return 0;
}

/* Lua: pve_root(object address): keeps an object loaded for good (UObject::AddToRoot). Mods hold assets in Lua tables, which
   the garbage collector can't see, so a loaded sound or mesh got freed under them. */
#define OBJECT_CHUNKS   0x58e7538  /* GUObjectArray's chunk table */
#define OBJECT_INDEX    0xc        /* UObject.InternalIndex */
#define ROOT_SET        (1 << 30)  /* FUObjectItem.Flags at +8; items are 24 bytes, 65536 to a chunk */

__declspec(dllexport) int pve_root(void *L) {
    char *obj = (char *)intArg(L, 1, 1);
    if (!obj) return 0;
    char **chunks = *(char ***)((char *)GetModuleHandleA(NULL) + OBJECT_CHUNKS);
    int index = *(int *)(obj + OBJECT_INDEX);
    if (chunks && index >= 0) {
        volatile long *flags = (volatile long *)(chunks[index >> 16] + (index & 0xffff) * 24 + 8);
        InterlockedOr(flags, ROOT_SET);
    }
    return 0;
}

/* Lua: pve_stash_rows(inventory component, rows): the stash height, a save option (launcher). USIGISInventoryComponent's
   InventoryContainerSizes is a TMap<FString, {u8 Column, u8 Row}>: 32-byte elements, key first, size at +0x10. Lua can't read
   its FString keys. The grid widget builds itself from this, so it has to be written before the inventory menu is. */
#define INV_SIZES 0x128

__declspec(dllexport) int pve_stash_rows(void *L) {
    char *comp = (char *)intArg(L, 1, 2);
    long long rows = intArg(L, 2, 2);
    if (!comp || rows < 1 || rows > 200) return 0;
    char *data = *(char **)(comp + INV_SIZES);
    int num = *(int *)(comp + INV_SIZES + 8);
    for (int i = 0; data && i < num; i++) {
        char *e = data + i * 32;
        wchar_t *key = *(wchar_t **)e;
        int len = *(int *)(e + 8);
        if (len == 6 && !IsBadReadPtr(key, 12) && !wcscmp(key, L"Stash")) *(unsigned char *)(e + 0x11) = (unsigned char)rows;
    }
    return 0;
}


/* Lua: pve_keep_worn(bot): empties a bot's bags and pockets, keeping what it wears. ARaidNodeBot.BotLootItems (+0xbf0) holds
   every item the bot carries (the death routines copy it into the corpse), worn ones in their equipment slot's container
   (ASIGISInventoryItem.MotherItemGUID +0x278: Head, Prim, Rig, Bag...), the rest in a bag's id or LootPocketLeft. The array
   is compacted in place and its Num lowered: it never grows here. Dropped items stay as unused actors. Returns nothing;
   the count kept is written to bridge/keep_worn.txt only when that file exists (testing). */
#define BOT_LOOT_ITEMS 0xbf0
#define ITEM_CONTAINER 0x278

static const wchar_t *WORN[] = { L"Head", L"Chest", L"Legs", L"Rig", L"Prim", L"Sec", L"Pistol", L"Melee", L"Bag", L"Ship",
                                 L"KeyCard", L"GuildBadge" };

static int isWorn(char *item) {
    if (!item || IsBadReadPtr(item + ITEM_CONTAINER, 16)) return 1; /* unreadable: keep it, never drop blind */
    wchar_t *s = *(wchar_t **)(item + ITEM_CONTAINER);
    int len = *(int *)(item + ITEM_CONTAINER + 8);
    if (!s || len <= 1 || len > 64 || IsBadReadPtr(s, len * 2)) return 0;
    for (unsigned i = 0; i < sizeof WORN / sizeof WORN[0]; i++) if (!wcscmp(s, WORN[i])) return 1;
    return 0;
}

__declspec(dllexport) int pve_keep_worn(void *L) {
    char *bot = (char *)intArg(L, 1, 1);
    if (!bot) return 0;
    char ***data = (char ***)(bot + BOT_LOOT_ITEMS);
    int *num = (int *)(bot + BOT_LOOT_ITEMS + 8), *max = (int *)(bot + BOT_LOOT_ITEMS + 12);
    if (!*data || *num < 0 || *num > *max || *max > 4096) return 0;
    int kept = 0, was = *num;
    for (int i = 0; i < was; i++) {
        char *it = (*data)[i];
        if (isWorn(it)) (*data)[kept++] = it;
    }
    *num = kept;
    FILE *f = report("keep_worn.txt", "r+");
    if (f) { fseek(f, 0, SEEK_END); fprintf(f, "%d of %d kept\n", kept, was); fclose(f); }
    return 0;
}

/* Lua: pve_array_grow(TArray address, element size): one zeroed element added in the array's spare room (Num < Max).
   Never reallocates: the engine's allocator owns the buffer. A zeroed FString is a valid empty one. The caller checks
   the array's length to see whether it worked (killstats.lua: a K_Human entry in PlayerState.InMatchStats). */
__declspec(dllexport) int pve_array_grow(void *L) {
    FArr *a = (FArr *)intArg(L, 1, 2);
    long long size = intArg(L, 2, 2);
    if (!a || size <= 0 || size > 256 || IsBadWritePtr(a, sizeof *a)) return 0;
    if (!a->data || a->num < 0 || a->num >= a->max || a->max > 4096) return 0;
    char *slot = (char *)a->data + (long long)a->num * size;
    if (IsBadWritePtr(slot, (UINT_PTR)size)) return 0;
    memset(slot, 0, (size_t)size);
    a->num++;
    return 0;
}
