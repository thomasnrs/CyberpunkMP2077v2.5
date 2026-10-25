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

    private cb func OnLoad() {
        GameInstance.GetCallbackSystem().RegisterCallback(n"Entity/Attached", this, n"OnNpcAttached")
            .AddTarget(EntityTarget.Type(n"NPCPuppet"));
    }

    private cb func OnNpcAttached(event: ref<EntityLifecycleEvent>) {
        let npc = event.GetEntity() as NPCPuppet;
        // Our own puppets - players, hitboxes and mirrors - are never reported back.
        if !IsDefined(npc) || npc.HasTag(n"CyberpunkMP.Puppet") {
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
    if !IsDefined(network) || !network.IsConnected() || !network.IsWorldHost() || !IsDefined(player) {
        return;
    }

    let service = MpWorldNpcService.Get();
    if !IsDefined(service) {
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
