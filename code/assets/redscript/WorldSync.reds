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

        ArrayPush(this.npcs, npc);
        ArrayPush(this.lastPositions, npc.GetWorldPosition());
        ArrayPush(this.lastTimes, -1.0);
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

public func MpUpdateGuestHiding(network: ref<NetworkWorldSystem>, service: ref<MpWorldNpcService>, player: ref<PlayerPuppet>) -> Void {
    // Twice a second is plenty for something that changes as people walk.
    service.hideTick += 1;
    if service.hideTick % 5 != 0 {
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
                MpSetWorldSyncHidden(npc, player, true);
            } else if npc.m_mpWorldSyncHidden {
                MpSetWorldSyncHidden(npc, player, false);
            }
        }
        i += 1;
    }
}

public func MpSetWorldSyncHidden(npc: ref<NPCPuppet>, player: ref<PlayerPuppet>, hidden: Bool) -> Void {
    let first = (hidden && !npc.m_mpWorldSyncHidden) || (!hidden && npc.m_mpWorldSyncHidden);

    // Re-applied while hidden, not only on the edge: appearance work switches meshes back on.
    let components = npc.GetComponents();
    let i = 0;
    while i < ArraySize(components) {
        if IsDefined(components[i]) {
            let name = NameToString(components[i].GetClassName());
            if StrContains(name, "Mesh") || Equals(name, "gameHitRepresentationComponent") {
                let enabled = components[i].IsEnabled();
                if (hidden && enabled) || (!hidden && !enabled) {
                    components[i].Toggle(!hidden);
                }
            }
        }
        i += 1;
    }

    if !first {
        return;
    }

    let theirs = npc.GetAttitudeAgent();
    let mine = player.GetAttitudeAgent();
    if IsDefined(theirs) && IsDefined(mine) {
        if hidden {
            npc.m_mpPriorAttitude = theirs.GetAttitudeTowards(mine);
            theirs.SetAttitudeTowards(mine, EAIAttitude.AIA_Friendly);
        } else {
            theirs.SetAttitudeTowards(mine, npc.m_mpPriorAttitude);
        }
    }

    npc.m_mpWorldSyncHidden = hidden;
    MpFTLog(s"[WorldNpc] own NPC \(EntityID.GetHash(npc.GetEntityID())) \(hidden ? "hidden - the host's copy stands in" : "back - no host copy near")");
}

public static func MpWorldNpcRange() -> Float = 60.0
public static func MpWorldNpcMaxPerReport() -> Int32 = 40

public class MpWorldNpcReportPoll extends DelayCallback {
    public let owner: wref<PlayerPuppet>;
    public let token: Int32;

    public func Call() -> Void {
        if !MpPollIsCurrent(this.owner, this.token) {
            return;
        }

        MpReportWorldNpcs(this.owner);

        let again = new MpWorldNpcReportPoll();
        again.owner = this.owner;
        again.token = this.token;
        GameInstance.GetDelaySystem(GetGameInstance()).DelayCallback(again, 0.1, false);
    }
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

    if !network.IsConnected() || !network.IsWorldHost() {
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
    let reported = 0;

    let i = 0;
    while i < ArraySize(service.npcs) {
        let npc = service.npcs[i];
        if IsDefined(npc) && npc.IsAttached() {
            let position = npc.GetWorldPosition();
            let lastTime = service.lastTimes[i];
            let speed = 0.0;
            if lastTime >= 0.0 && now > lastTime {
                speed = Vector4.Distance(position, service.lastPositions[i]) / (now - lastTime);
            }

            if !npc.IsCrowd() && reported < MpWorldNpcMaxPerReport()
                && Vector4.Distance(position, center) <= range {
                // Yaw 0 looks down +Y; forward at yaw a is (-sin a, cos a).
                let forward = npc.GetWorldForward();
                network.ReportWorldNpc(
                    Cast<Uint64>(EntityID.GetHash(npc.GetEntityID())),
                    TDBID.ToNumber(npc.GetRecordID()),
                    position,
                    AtanF(-forward.X, forward.Y),
                    speed,
                    npc.IsDead() ? 2u : 0u);
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

    network.FlushWorldNpcReport();
}
