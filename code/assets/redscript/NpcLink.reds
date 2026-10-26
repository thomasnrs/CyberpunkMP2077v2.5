module CyberpunkMP

import CyberpunkMP.World.*

/**
 * Shared NPC combat - two players fighting the same gang.
 *
 * Every game keeps its own NPCs, entirely its own: their AI, the gig, the police. What a player
 * does to one of theirs - a hit, a kill, a knockout - goes to the other games (NpcLinkEvent,
 * relayed by WorldNpcSystem on the server), and each applies it to ITS NPC of the same record
 * near the same spot. A gig's gangers spawn at the same points on every machine, so "same
 * record, at the same spawn point or standing in the same place" finds the same ganger; once
 * found, the pairing is kept for the rest of the fight.
 *
 * Replaces the host model (WorldSync.reds, config/worldnpc.on), which copied one game's NPCs
 * onto the others and hid theirs: in a fight the game re-creates its NPCs constantly, and a
 * hidden NPC is still a living one that shoots.
 *
 * Crowd NPCs are left out - two games' pedestrians are different people - and so is anything
 * the game protects (god mode): a quest NPC that cannot die here must not die through a link.
 */

// How far apart the two games' copies of one NPC may be, by spawn point or by where they
// stand, and still be taken for the same one.
public static func MpNpcLinkMatchRange() -> Float = 15.0

// Deaths and knockouts are watched around the player this far out.
public static func MpNpcLinkWatchRange() -> Float = 120.0

public func MpNpcLinkAllowed(npc: ref<NPCPuppet>) -> Bool {
    if !IsDefined(npc) || npc.IsCrowd() || npc.HasTag(n"CyberpunkMP.Puppet") {
        return false;
    }

    let gods = GameInstance.GetGodModeSystem(npc.GetGame());
    let id = npc.GetEntityID();
    return !gods.HasGodMode(id, gameGodModeType.Immortal) && !gods.HasGodMode(id, gameGodModeType.Invulnerable);
}

public func MpIsKnockedOut(npc: ref<NPCPuppet>) -> Bool {
    return GameInstance.GetStatusEffectSystem(npc.GetGame()).HasStatusEffect(npc.GetEntityID(), t"BaseStatusEffect.Unconscious");
}

// Where an NPC was first seen - its spawn point, the same on every machine - by id, so a fresh
// object swapped in for it mid-fight still knows. Its current position when unknown.
public func MpNpcSpawnOf(service: ref<MpWorldNpcService>, npc: ref<NPCPuppet>) -> Vector4 {
    let id = Cast<Uint64>(EntityID.GetHash(npc.GetEntityID()));
    let i = 0;
    while i < ArraySize(service.spawnIds) {
        if Equals(service.spawnIds[i], id) {
            return service.spawnPositions[i];
        }
        i += 1;
    }
    return npc.GetWorldPosition();
}

public func MpNoteNpcSpawn(service: ref<MpWorldNpcService>, npc: ref<NPCPuppet>) -> Void {
    let id = Cast<Uint64>(EntityID.GetHash(npc.GetEntityID()));
    if ArrayContains(service.spawnIds, id) {
        return;
    }

    // Bounded: the oldest go first, long gone by the time this fills.
    if ArraySize(service.spawnIds) >= 4096 {
        ArrayErase(service.spawnIds, 0);
        ArrayErase(service.spawnPositions, 0);
    }
    ArrayPush(service.spawnIds, id);
    ArrayPush(service.spawnPositions, npc.GetWorldPosition());
}

public func MpSendNpcLink(npc: ref<NPCPuppet>, damagePct: Float, killed: Bool, defeated: Bool) -> Void {
    let network = GameInstance.GetNetworkWorldSystem();
    let service = MpWorldNpcService.Get();
    if !IsDefined(network) || !network.IsConnected() || !IsDefined(service) {
        return;
    }

    network.SendNpcLink(
        Cast<Uint64>(EntityID.GetHash(npc.GetEntityID())),
        TDBID.ToNumber(npc.GetRecordID()),
        npc.GetWorldPosition(),
        MpNpcSpawnOf(service, npc),
        damagePct,
        killed,
        defeated);
}

/**
 * Sender, hits: called from Combat.reds' DamagePipelineFinalized for every NPC that is not one
 * of our puppets. Only OUR hits travel - every game sees its own player's - as a share of the
 * NPC's maximum health, so a ganger a level apart on the other machine loses the same part.
 */
public func MpShareNpcHit(npc: ref<NPCPuppet>, evt: ref<gameHitEvent>) -> Void {
    if !MpNpcLinkAllowed(npc) || !IsDefined(evt) || !IsDefined(evt.attackComputed) {
        return;
    }

    let player = GetPlayer(npc.GetGame());
    let instigator = evt.attackData.GetInstigator();
    if !IsDefined(player) || !IsDefined(instigator) || NotEquals(instigator.GetEntityID(), player.GetEntityID()) {
        return;
    }

    let damage = evt.attackComputed.GetTotalAttackValue(gamedataStatPoolType.Health);
    let maxHealth = GameInstance.GetStatPoolsSystem(npc.GetGame())
        .GetStatPoolMaxPointValue(Cast<StatsObjectID>(npc.GetEntityID()), gamedataStatPoolType.Health);
    if damage <= 0.0 || maxHealth <= 0.0 {
        return;
    }

    MpSendNpcLink(npc, MinF(damage * 100.0 / maxHealth, 100.0), false, false);
}

/**
 * Sender, deaths and knockouts - whatever caused them, since dead here is dead for everybody.
 * Only a change this object was seen making: a corpse streaming back in is not a new death,
 * and must not kill a living ganger of the same record standing near it on another machine.
 *
 * m_mpLinkState is how far down it is (0 up, 1 knocked out, 2 dead); m_mpLinkAppliedState is
 * how far a link took it, so what arrived from another game is not sent back to it.
 */
@addField(ScriptedPuppet)
public let m_mpLinkSeenUp: Bool;

@addField(ScriptedPuppet)
public let m_mpLinkState: Int32;

@addField(ScriptedPuppet)
public let m_mpLinkAppliedState: Int32;

public func MpWatchNpcDowns(service: ref<MpWorldNpcService>, player: ref<PlayerPuppet>) -> Void {
    let center = player.GetWorldPosition();
    let range = MpNpcLinkWatchRange();

    let i = 0;
    while i < ArraySize(service.npcs) {
        let npc = service.npcs[i];
        if IsDefined(npc) && npc.IsAttached() && !npc.IsCrowd() && Vector4.Distance(npc.GetWorldPosition(), center) <= range {
            let state = npc.IsDead() ? 2 : (MpIsKnockedOut(npc) ? 1 : 0);
            if state == 0 {
                npc.m_mpLinkSeenUp = true;
            } else if npc.m_mpLinkSeenUp && state > npc.m_mpLinkState {
                npc.m_mpLinkState = state;
                if state > npc.m_mpLinkAppliedState && MpNpcLinkAllowed(npc) {
                    MpSendNpcLink(npc, 0.0, state == 2, state == 1);
                    MpFTLog(s"[NpcLink] our NPC \(EntityID.GetHash(npc.GetEntityID())) \(state == 2 ? "died" : "was knocked out") - told the others");
                }
            }
        }
        i += 1;
    }
}

/**
 * Receiver: the pairing. A pair found once is kept - (sender, their id) to our NPC - so every
 * later hit lands on the same ganger. It is looked for again when ours has gone (streamed out,
 * or swapped for a fresh object, which then usually matches again by its spawn point).
 */
public func MpFindLinkedNpc(service: ref<MpWorldNpcService>, source: Uint64, remoteId: Uint64, record: Uint64,
                            position: Vector4, spawn: Vector4) -> ref<NPCPuppet> {
    let i = 0;
    while i < ArraySize(service.linkNpcs) {
        if Equals(service.linkSources[i], source) && Equals(service.linkRemoteIds[i], remoteId) {
            let linked = service.linkNpcs[i];
            if IsDefined(linked) && linked.IsAttached() && !linked.IsDead() {
                return linked;
            }
            ArrayErase(service.linkSources, i);
            ArrayErase(service.linkRemoteIds, i);
            ArrayErase(service.linkNpcs, i);
            break;
        }
        i += 1;
    }

    let best: ref<NPCPuppet>;
    let bestCost = MpNpcLinkMatchRange();
    i = 0;
    while i < ArraySize(service.npcs) {
        let npc = service.npcs[i];
        if IsDefined(npc) && npc.IsAttached() && !npc.IsCrowd() && !npc.IsDead()
            && Equals(TDBID.ToNumber(npc.GetRecordID()), record) && !MpIsLinkedFrom(service, source, npc) {
            let cost = MinF(Vector4.Distance(npc.GetWorldPosition(), position), Vector4.Distance(MpNpcSpawnOf(service, npc), spawn));
            if cost < bestCost {
                best = npc;
                bestCost = cost;
            }
        }
        i += 1;
    }

    if IsDefined(best) {
        if ArraySize(service.linkNpcs) >= 256 {
            ArrayErase(service.linkSources, 0);
            ArrayErase(service.linkRemoteIds, 0);
            ArrayErase(service.linkNpcs, 0);
        }
        ArrayPush(service.linkSources, source);
        ArrayPush(service.linkRemoteIds, remoteId);
        ArrayPush(service.linkNpcs, best);
        MpFTLog(s"[NpcLink] their NPC \(remoteId) is our \(EntityID.GetHash(best.GetEntityID())) (\(bestCost) m apart)");
    }
    return best;
}

public func MpIsLinkedFrom(service: ref<MpWorldNpcService>, source: Uint64, npc: ref<NPCPuppet>) -> Bool {
    let i = 0;
    while i < ArraySize(service.linkNpcs) {
        if Equals(service.linkSources[i], source) && service.linkNpcs[i] == npc {
            return true;
        }
        i += 1;
    }
    return false;
}

/**
 * Receiver: what another player did, done to our copy. Credited to our own player, so our
 * ganger turns on us as it would have if we had fired - when they start a fight, it is ours
 * too.
 */
public func MpApplyNpcLinks(network: ref<NetworkWorldSystem>, service: ref<MpWorldNpcService>, player: ref<PlayerPuppet>) -> Void {
    while network.ConsumeNpcLink() {
        let killed = network.GetNpcLinkKilled();
        let defeated = network.GetNpcLinkDefeated();
        let damage = network.GetNpcLinkDamage();
        let remoteId = network.GetNpcLinkLocalId();

        let npc = MpFindLinkedNpc(service, network.GetNpcLinkSource(), remoteId, network.GetNpcLinkRecord(),
                                  network.GetNpcLinkPosition(), network.GetNpcLinkSpawn());
        if !IsDefined(npc) {
            if killed || defeated || service.linkMisses < 20 {
                service.linkMisses += 1;
                MpFTLog(s"[NpcLink] their NPC \(remoteId) \(killed ? "died" : (defeated ? "was knocked out" : s"took \(damage)%")) - no NPC of ours matches it");
            }
        } else if MpNpcLinkAllowed(npc) && !npc.IsDead() {
            let id = Cast<StatsObjectID>(npc.GetEntityID());
            let pools = GameInstance.GetStatPoolsSystem(npc.GetGame());
            let maxHealth = pools.GetStatPoolMaxPointValue(id, gamedataStatPoolType.Health);

            if killed {
                npc.m_mpLinkAppliedState = 2;
                pools.RequestChangingStatPoolValue(id, gamedataStatPoolType.Health, -(maxHealth * 2.0 + 1000.0), player, false, false);
                MpFTLog(s"[NpcLink] their NPC \(remoteId) died - so did our \(EntityID.GetHash(npc.GetEntityID()))");
            } else if defeated {
                if !MpIsKnockedOut(npc) {
                    npc.m_mpLinkAppliedState = 1;
                    StatusEffectHelper.ApplyStatusEffect(npc, t"BaseStatusEffect.Unconscious");
                    MpFTLog(s"[NpcLink] their NPC \(remoteId) was knocked out - so was our \(EntityID.GetHash(npc.GetEntityID()))");
                }
            } else if maxHealth > 0.0 {
                pools.RequestChangingStatPoolValue(id, gamedataStatPoolType.Health, -(maxHealth * damage / 100.0), player, false, false);
                if service.linkHitsLogged < 30 {
                    service.linkHitsLogged += 1;
                    MpFTLog(s"[NpcLink] their NPC \(remoteId) took \(damage)% - applied to our \(EntityID.GetHash(npc.GetEntityID()))");
                }
            }
        }
    }
}

// From the 60/s world poll (WorldSync.reds' MpReportWorldNpcs), host or not.
public func MpUpdateNpcLinks(network: ref<NetworkWorldSystem>, service: ref<MpWorldNpcService>, player: ref<PlayerPuppet>) -> Void {
    if !network.IsConnected() {
        return;
    }

    MpApplyNpcLinks(network, service, player);

    // Ten times a second is soon enough to notice a death.
    service.linkTick += 1;
    if service.linkTick % 6 == 0 {
        MpWatchNpcDowns(service, player);
    }
}
