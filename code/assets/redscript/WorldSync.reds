module CyberpunkMP

import Codeware.*
import CyberpunkMP.World.*

/**
 * World sync, host model - the host's half.
 *
 * Each machine runs its own city, and its NPCs' EntityIDs are dynamic: twenty NPCs hit, not
 * one static id, so the same ganger cannot be found on two machines. One player is the world
 * host (the server says who, NotifyWorldHost). The host's game simulates its NPCs as normal;
 * this reports the ones near the host to the server ten times a second, and the server
 * mirrors each one to every other client (WorldNpcSystem).
 *
 * Crowd and traffic stay local for now - nobody can tell two cities' pedestrians apart. Gang
 * members, police and gig targets are what a mission is made of, and those are reported.
 */

// Hears about every NPC that enters the world, from game start, so none present before a
// connect is missed. A ScriptableService lives for the whole game session, across worlds.
public class MpWorldNpcService extends ScriptableService {
    public let npcs: array<wref<NPCPuppet>>;
    public let lastPositions: array<Vector4>;
    public let lastTimes: array<Float>;

    // Mirrors of the host's NPCs that this client is showing (see MpUpdateGuestHiding).
    public let mirrors: array<wref<NPCPuppet>>;
    public let hideTick: Int32;

    // Every attachment slot there is (see MpHideHeldItems), read from TweakDB once, and the
    // few that have ever held something - the only ones worth checking every frame.
    public let heldSlots: array<TweakDBID>;
    public let heldSlotsLoaded: Bool;
    public let usedSlots: array<TweakDBID>;

    // Who the last report carried, by id. The game swaps an NPC for a fresh object with the
    // same id many times a fight; a flag on the object forgot, every time, that it was
    // already being reported (see MpWorldNpcKeepRange).
    public let reportedIds: array<Uint64>;

    // Shared NPC combat (NpcLink.reds): every NPC's first-seen position by id, and the
    // pairings of other players' NPCs with ours.
    public let spawnIds: array<Uint64>;
    public let spawnPositions: array<Vector4>;
    public let linkSources: array<Uint64>;
    public let linkRemoteIds: array<Uint64>;
    public let linkNpcs: array<wref<NPCPuppet>>;
    public let linkTick: Int32;
    public let linkMisses: Int32;
    public let linkHitsLogged: Int32;
    public let pruneTick: Int32;

    private cb func OnLoad() {
        GameInstance.GetCallbackSystem().RegisterCallback(n"Entity/Attached", this, n"OnNpcAttached")
            .AddTarget(EntityTarget.Type(n"NPCPuppet"));
    }

    private cb func OnNpcAttached(event: ref<EntityLifecycleEvent>) {
        let npc = event.GetEntity() as NPCPuppet;
        if !IsDefined(npc) {
            return;
        }

        // Our own puppets - players, hitboxes and mirrors - are never reported back. The
        // mirrors are remembered: where they stand is where this game's own NPCs give way.
        if npc.HasTag(n"CyberpunkMP.Puppet") {
            if !MpIsPlayerBodyRecord(npc.GetRecordID()) {
                ArrayPush(this.mirrors, npc);
            }
            return;
        }

        MpNoteNpcSpawn(this, npc);

        // The same object can attach again; one entry each, or it is reported twice.
        let i = 0;
        while i < ArraySize(this.npcs) {
            if this.npcs[i] == npc {
                return;
            }
            i += 1;
        }

        ArrayPush(this.npcs, npc);
        ArrayPush(this.lastPositions, npc.GetWorldPosition());
        ArrayPush(this.lastTimes, -1.0);

        // The game streams NPCs out and back in as fresh objects; waiting for the next
        // half-second pass showed each one for a moment every time it came back - the flicker.
        // Hidden on arrival if a host copy already stands near.
        if this.IsNearMirror(npc.GetWorldPosition()) {
            let player = GetPlayer(npc.GetGame());
            if IsDefined(player) && !npc.IsCrowd() {
                MpSetWorldSyncHidden(this, npc, player, true);
            }
        }
    }

    public func IsNearMirror(position: Vector4) -> Bool {
        let range = MpWorldSyncHideRange();
        let i = 0;
        while i < ArraySize(this.mirrors) {
            let mirror = this.mirrors[i];
            if IsDefined(mirror) && mirror.IsAttached() && Vector4.Distance(position, mirror.GetWorldPosition()) <= range {
                return true;
            }
            i += 1;
        }
        return false;
    }

    public static func Get() -> ref<MpWorldNpcService> {
        return GameInstance.GetScriptableServiceContainer().GetService(n"CyberpunkMP.MpWorldNpcService") as MpWorldNpcService;
    }
}

/**
 * Hits other players landed on the mirrors of our NPCs, forwarded by the server: applied to
 * the real NPC here, the one simulation that counts. If it dies, the next report says so and
 * every mirror goes down with it.
 */
public func MpApplyWorldNpcDamage(network: ref<NetworkWorldSystem>, service: ref<MpWorldNpcService>, player: ref<PlayerPuppet>) -> Void {
    let localId = network.ConsumeWorldNpcDamage();

    while NotEquals(localId, 0ul) {
        let damage = network.GetConsumedWorldNpcDamage();
        let applied = false;

        let i = 0;
        while i < ArraySize(service.npcs) && !applied {
            let npc = service.npcs[i];
            if IsDefined(npc) && Equals(Cast<Uint64>(EntityID.GetHash(npc.GetEntityID())), localId) {
                GameInstance.GetStatPoolsSystem(npc.GetGame()).RequestChangingStatPoolValue(
                    Cast<StatsObjectID>(npc.GetEntityID()), gamedataStatPoolType.Health, -damage, player, false, false);
                applied = true;
            }
            i += 1;
        }

        MpFTLog(s"[WorldNpc] a mirror of NPC \(localId) was hit for \(damage) - \(applied ? "applied to it" : "no such NPC here any more")");
        localId = network.ConsumeWorldNpcDamage();
    }
}

public func MpIsPlayerBodyRecord(rec: TweakDBID) -> Bool {
    return Equals(rec, t"Character.MaMuppet") || Equals(rec, t"Character.WaMuppet")
        || Equals(rec, t"Character.Player_Puppet_Base") || Equals(rec, t"Character.MpHitbox");
}

/**
 * The guest's half: this game's own gangers, police and targets give way to the host's.
 *
 * Mirrors exist only around the host (that is what the host reports), so any of this game's
 * non-crowd NPCs within reach of a mirror is a duplicate of something the host is already
 * simulating for everybody. It is hidden - meshes and hit representation off, so it is not
 * seen and shots land on the mirror instead - and made friendly toward us, so it cannot shoot
 * from nowhere. Its physics stays: switched off, it falls through the floor. When no mirror
 * is near any more (the host moved on), it comes back as it was.
 *
 * With npcmirror.echo the host receives its own mirrors and hides its originals - exactly the
 * guest's view, for one person to look at.
 */
@addField(ScriptedPuppet)
public let m_mpWorldSyncHidden: Bool;

@addField(ScriptedPuppet)
public let m_mpPriorAttitude: EAIAttitude;

public static func MpWorldSyncHideRange() -> Float = 70.0

@addField(ScriptedPuppet)
public let m_mpHideScans: Int32;

public func MpUpdateGuestHiding(network: ref<NetworkWorldSystem>, service: ref<MpWorldNpcService>, player: ref<PlayerPuppet>) -> Void {
    service.hideTick += 1;

    // Every frame: the hidden stay hidden. In a fight the game swaps an NPC for a fresh
    // object with the same id several times a second, and the fresh one switches its meshes
    // on as its appearance loads; checked a few times a second, each one showed for a moment
    // - the ones that kept "coming back and vanishing".
    let i = 0;
    while i < ArraySize(service.npcs) {
        let npc = service.npcs[i];
        if IsDefined(npc) && npc.m_mpWorldSyncHidden {
            MpKeepWorldSyncHidden(service, npc);
        }
        i += 1;
    }

    // Who should be hidden changes as people walk: six times a second is plenty.
    if service.hideTick % 10 != 0 {
        return;
    }

    let mirrorPositions: array<Vector4>;
    let keptMirrors: array<wref<NPCPuppet>>;
    let i = 0;
    while i < ArraySize(service.mirrors) {
        let mirror = service.mirrors[i];
        if IsDefined(mirror) && mirror.IsAttached() {
            ArrayPush(keptMirrors, mirror);
            ArrayPush(mirrorPositions, mirror.GetWorldPosition());
        }
        i += 1;
    }
    service.mirrors = keptMirrors;

    let active = network.IsConnected() && ArraySize(mirrorPositions) > 0;
    let range = MpWorldSyncHideRange();

    i = 0;
    while i < ArraySize(service.npcs) {
        let npc = service.npcs[i];
        if IsDefined(npc) && npc.IsAttached() && !npc.IsCrowd() {
            let near = false;
            if active {
                let position = npc.GetWorldPosition();
                let j = 0;
                while j < ArraySize(mirrorPositions) && !near {
                    near = Vector4.Distance(position, mirrorPositions[j]) <= range;
                    j += 1;
                }
            }

            if near {
                MpSetWorldSyncHidden(service, npc, player, true);
            } else if npc.m_mpWorldSyncHidden {
                MpSetWorldSyncHidden(service, npc, player, false);
            }
        }
        i += 1;
    }
}

@addField(ScriptedPuppet)
public let m_mpAttitudeChanged: Bool;

public func MpSetWorldSyncHidden(service: ref<MpWorldNpcService>, npc: ref<NPCPuppet>, player: ref<PlayerPuppet>, hidden: Bool) -> Void {
    let first = (hidden && !npc.m_mpWorldSyncHidden) || (!hidden && npc.m_mpWorldSyncHidden);

    // Re-applied while hidden, not only on the edge: appearance work switches meshes back on.
    // Back on are only the ones switched off here - an NPC carries meshes the game keeps off
    // (damage, other variants), and turning every one on dressed it in all of them.
    let held = 0;
    if hidden {
        if first {
            npc.m_mpHideScans = 0;
        }
        MpHideWorldSyncMeshes(npc, npc, true);
        // All 300-odd slots on arrival and once a second; the ones ever used in between.
        held = MpHideHeldItems(service, npc, first || service.hideTick % 60 == 0);
    } else {
        let i = 0;
        while i < ArraySize(npc.m_mpHiddenComponents) {
            let component = npc.m_mpHiddenComponents[i];
            if IsDefined(component) && !component.IsEnabled() {
                component.Toggle(true);
            }
            i += 1;
        }
        ArrayClear(npc.m_mpHiddenComponents);
    }

    if !first {
        return;
    }

    // The host's own NPCs (hidden only when echo shows it its mirrors) ARE the simulation
    // everybody sees: made friendly, they stopped fighting the host, and the mirrors had
    // nothing to copy. Only a guest's duplicates are pacified.
    let network = GameInstance.GetNetworkWorldSystem();
    let isHost = IsDefined(network) && network.IsWorldHost();
    let theirs = npc.GetAttitudeAgent();
    let mine = player.GetAttitudeAgent();
    if IsDefined(theirs) && IsDefined(mine) {
        if hidden && !isHost {
            npc.m_mpPriorAttitude = theirs.GetAttitudeTowards(mine);
            theirs.SetAttitudeTowards(mine, EAIAttitude.AIA_Friendly);
            npc.m_mpAttitudeChanged = true;
        } else if !hidden && npc.m_mpAttitudeChanged {
            theirs.SetAttitudeTowards(mine, npc.m_mpPriorAttitude);
            npc.m_mpAttitudeChanged = false;
        }
    }

    npc.m_mpWorldSyncHidden = hidden;
    MpFTLog(s"[WorldNpc] own NPC \(EntityID.GetHash(npc.GetEntityID())) \(hidden ? "hidden - the host's copy stands in" : "back - no host copy near") (\(held) held items)");
}

@addField(ScriptedPuppet)
public let m_mpHiddenComponents: array<wref<IComponent>>;

// The every-frame half of hiding: what was switched off and came back on goes off again, and
// for its first second - while a fresh object is still assembling - everything is looked at.
public func MpKeepWorldSyncHidden(service: ref<MpWorldNpcService>, npc: ref<NPCPuppet>) -> Void {
    let i = 0;
    while i < ArraySize(npc.m_mpHiddenComponents) {
        let component = npc.m_mpHiddenComponents[i];
        if IsDefined(component) && component.IsEnabled() {
            component.Toggle(false);
        }
        i += 1;
    }

    if npc.m_mpHideScans < 60 {
        npc.m_mpHideScans += 1;
        MpHideWorldSyncMeshes(npc, npc, true);
        MpHideHeldItems(service, npc, false);
    }
}

public func MpHideWorldSyncMeshes(npc: ref<ScriptedPuppet>, entity: ref<Entity>, hitToo: Bool) -> Void {
    let components = entity.GetComponents();
    let i = 0;
    while i < ArraySize(components) {
        let component = components[i];
        if IsDefined(component) && component.IsEnabled() {
            let name = NameToString(component.GetClassName());
            if StrContains(name, "Mesh") || (hitToo && Equals(name, "gameHitRepresentationComponent")) {
                component.Toggle(false);
                ArrayPush(npc.m_mpHiddenComponents, component);
            }
        }
        i += 1;
    }
}

/**
 * Hidden NPCs and the things in their hands - the floating guitar.
 *
 * What an NPC holds (a gun, a phone, a guitar from its workspot) is an entity of its own,
 * attached to one of the NPC's slots: switching the NPC's meshes off left it hanging in the
 * air. Every slot is looked at (allSlots), since workspot props use slots weapons never do;
 * the ones found holding something are remembered and checked on their own in between.
 * Returns how many items were found.
 */
public func MpHideHeldItems(service: ref<MpWorldNpcService>, npc: ref<NPCPuppet>, allSlots: Bool) -> Int32 {
    if !service.heldSlotsLoaded {
        service.heldSlotsLoaded = true;
        let records = TweakDBInterface.GetRecords(n"AttachmentSlot");
        if ArraySize(records) == 0 {
            records = TweakDBInterface.GetRecords(n"gamedataAttachmentSlot_Record");
        }
        let r = 0;
        while r < ArraySize(records) {
            ArrayPush(service.heldSlots, records[r].GetID());
            r += 1;
        }
        // The two everyone uses, whatever TweakDB said.
        if !ArrayContains(service.heldSlots, t"AttachmentSlots.WeaponRight") {
            ArrayPush(service.heldSlots, t"AttachmentSlots.WeaponRight");
        }
        if !ArrayContains(service.heldSlots, t"AttachmentSlots.WeaponLeft") {
            ArrayPush(service.heldSlots, t"AttachmentSlots.WeaponLeft");
        }
        ArrayPush(service.usedSlots, t"AttachmentSlots.WeaponRight");
        ArrayPush(service.usedSlots, t"AttachmentSlots.WeaponLeft");
        MpFTLog(s"[WorldNpc] \(ArraySize(records)) attachment slots in TweakDB, \(ArraySize(service.heldSlots)) checked on hidden NPCs");
    }

    let transactions = GameInstance.GetTransactionSystem(npc.GetGame());
    let found = 0;
    let i = 0;
    let count = allSlots ? ArraySize(service.heldSlots) : ArraySize(service.usedSlots);
    while i < count {
        let slot = allSlots ? service.heldSlots[i] : service.usedSlots[i];
        let item = transactions.GetItemInSlot(npc, slot);
        if IsDefined(item) {
            MpHideWorldSyncMeshes(npc, item, false);
            found += 1;
            if allSlots && !ArrayContains(service.usedSlots, slot) {
                ArrayPush(service.usedSlots, slot);
                MpFTLog(s"[WorldNpc] slot \(TDBID.ToStringDEBUG(slot)) holds things - checked every frame from now on");
            }
        }
        i += 1;
    }
    return found;
}

/**
 * The weapon in an NPC's hand and the rounds it fired since the last report, for the mirrors
 * to draw and fire the same way (WorldNpcSystem relays them as players' weapon events). A
 * magazine that dropped is shots; one that rose is a reload; a new weapon starts the count over.
 */
@addField(ScriptedPuppet)
public let m_mpWorldWeapon: Uint64;

@addField(ScriptedPuppet)
public let m_mpWorldAmmo: Int32;

@addField(ScriptedPuppet)
public let m_mpWorldAmmoKnown: Bool;

@addField(ScriptedPuppet)
public let m_mpWorldShotsLogged: Int32;

public func MpTrackWorldNpcWeapon(npc: ref<NPCPuppet>) -> Uint32 {
    let weapon = GameObject.GetActiveWeapon(npc);
    let record = 0ul;
    if IsDefined(weapon) && IsDefined(weapon.GetWeaponRecord()) {
        record = TDBID.ToNumber(weapon.GetWeaponRecord().GetID());
    }

    if NotEquals(record, npc.m_mpWorldWeapon) {
        npc.m_mpWorldAmmoKnown = false;
        MpFTLog(s"[WorldNpc] own NPC \(EntityID.GetHash(npc.GetEntityID())) \(Equals(record, 0ul) ? "holstered" : s"drew \(record)")");
    }
    npc.m_mpWorldWeapon = record;

    let shots = 0u;
    if NotEquals(record, 0ul) {
        let ammo = Cast<Int32>(WeaponObject.GetMagazineAmmoCount(weapon));
        if npc.m_mpWorldAmmoKnown && ammo < npc.m_mpWorldAmmo {
            shots = Cast<Uint32>(npc.m_mpWorldAmmo - ammo);
            if npc.m_mpWorldShotsLogged < 5 {
                npc.m_mpWorldShotsLogged += 1;
                MpFTLog(s"[WorldNpc] own NPC \(EntityID.GetHash(npc.GetEntityID())) fired \(shots) (magazine \(ammo))");
            }
        }
        npc.m_mpWorldAmmo = ammo;
        npc.m_mpWorldAmmoKnown = true;
    }
    return shots;
}

public static func MpWorldNpcRange() -> Float = 60.0
public static func MpWorldNpcKeepRange() -> Float = 85.0

@addField(ScriptedPuppet)
public let m_mpWorldReported: Bool;
// A gang fight fills 60 m with more than 40: the rest went unreported, their mirrors expired
// and came back as new ones.
public static func MpWorldNpcMaxPerReport() -> Int32 = 64

public class MpWorldNpcReportPoll extends DelayCallback {
    public let owner: wref<PlayerPuppet>;
    public let token: Int32;

    public func Call() -> Void {
        if !MpPollIsCurrent(this.owner, this.token) {
            return;
        }

        MpReportWorldNpcs(this.owner);

        // 60/s, the rate players send at (server.json UpdateRate). At 10/s the mirrors'
        // interpolation ran dry on ~22% of frames and guessed, then jumped when the truth
        // arrived. Every frame, at 60 fps or less.
        let again = new MpWorldNpcReportPoll();
        again.owner = this.owner;
        again.token = this.token;
        GameInstance.GetDelaySystem(GetGameInstance()).DelayCallback(again, 0.016, false);
    }
}

public func MpPruneWorldNpcs(service: ref<MpWorldNpcService>) -> Void {
    let keptNpcs: array<wref<NPCPuppet>>;
    let keptPositions: array<Vector4>;
    let keptTimes: array<Float>;

    let i = 0;
    while i < ArraySize(service.npcs) {
        let npc = service.npcs[i];
        if IsDefined(npc) && npc.IsAttached() {
            ArrayPush(keptNpcs, npc);
            ArrayPush(keptPositions, service.lastPositions[i]);
            ArrayPush(keptTimes, service.lastTimes[i]);
        }
        i += 1;
    }

    service.npcs = keptNpcs;
    service.lastPositions = keptPositions;
    service.lastTimes = keptTimes;
}

public func MpReportWorldNpcs(player: ref<PlayerPuppet>) -> Void {
    let network = GameInstance.GetNetworkWorldSystem();
    if !IsDefined(network) || !IsDefined(player) {
        return;
    }

    let service = MpWorldNpcService.Get();
    if !IsDefined(service) {
        return;
    }

    // Host or guest: give way to the host's NPCs wherever their mirrors stand.
    MpUpdateGuestHiding(network, service, player);

    // Everybody: hits and deaths shared with the other games' copies of our NPCs.
    MpUpdateNpcLinks(network, service, player);

    if !network.IsConnected() || !network.IsWorldHost() {
        // The host's report below rebuilds the list as it goes; nobody else's would ever let
        // go of an NPC that streamed out, and every loop over it would only grow.
        service.pruneTick += 1;
        if service.pruneTick % 120 == 0 {
            MpPruneWorldNpcs(service);
        }
        return;
    }

    MpApplyWorldNpcDamage(network, service, player);

    let now = EngineTime.ToFloat(GameInstance.GetSimTime(player.GetGame()));
    let center = player.GetWorldPosition();
    let range = MpWorldNpcRange();

    // Gone ones dropped, the rest reported - the three arrays rebuilt in step.
    let keptNpcs: array<wref<NPCPuppet>>;
    let keptPositions: array<Vector4>;
    let keptTimes: array<Float>;
    let reportedIds: array<Uint64>;
    let reported = 0;

    let i = 0;
    while i < ArraySize(service.npcs) {
        let npc = service.npcs[i];
        if IsDefined(npc) && npc.IsAttached() {
            let localId = Cast<Uint64>(EntityID.GetHash(npc.GetEntityID()));
            if npc.m_mpWorldReported || ArrayContains(service.reportedIds, localId) {
                npc.m_mpWorldReported = true;
            }
            let position = npc.GetWorldPosition();
            let lastTime = service.lastTimes[i];
            let speed = 0.0;
            if lastTime >= 0.0 && now > lastTime {
                speed = Vector4.Distance(position, service.lastPositions[i]) / (now - lastTime);
            }

            // In at the range, out only well past it: an NPC pacing along the edge was
            // reported, dropped and reported again, and every drop deleted and re-created its
            // mirror somewhere else - the "vanished" and "teleported" ones.
            let distance = Vector4.Distance(position, center);
            let inRange = distance <= range || (npc.m_mpWorldReported && distance <= MpWorldNpcKeepRange());
            npc.m_mpWorldReported = inRange && !npc.IsCrowd();

            // Once per id: an old object not yet detached and its fresh replacement are the
            // same NPC.
            if !npc.IsCrowd() && reported < MpWorldNpcMaxPerReport() && inRange && !ArrayContains(reportedIds, localId) {
                ArrayPush(reportedIds, localId);
                let shots = MpTrackWorldNpcWeapon(npc);

                // Yaw 0 looks down +Y; forward at yaw a is (-sin a, cos a).
                let forward = npc.GetWorldForward();
                network.ReportWorldNpc(
                    localId,
                    TDBID.ToNumber(npc.GetRecordID()),
                    position,
                    AtanF(-forward.X, forward.Y),
                    speed,
                    npc.IsDead() ? 2u : 0u,
                    npc.m_mpWorldWeapon,
                    shots);
                reported += 1;
            }

            ArrayPush(keptNpcs, npc);
            ArrayPush(keptPositions, position);
            ArrayPush(keptTimes, now);
        }
        i += 1;
    }

    service.npcs = keptNpcs;
    service.lastPositions = keptPositions;
    service.lastTimes = keptTimes;
    service.reportedIds = reportedIds;

    network.FlushWorldNpcReport();
}
