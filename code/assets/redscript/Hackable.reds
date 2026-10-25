module CyberpunkMP

import CyberpunkMP.World.*

/**
 * Makes a remote player a legitimate Cyberpunk combatant - shootable and hackable.
 *
 * THE TWO GATES, both read from the game's own source and both since confirmed live.
 *
 * Weapon targeting, TSF_EnemyNPC (core/gameplay/targetingSearchFilter.script:79):
 *
 *     All(Obj_Puppet | Att_Hostile | St_Alive) AND Not(Obj_Player)
 *
 * Quickhacking, ScriptedPuppet.IsQuickHackAble (cyberpunk/puppet/scriptedPuppet.script:4045):
 *
 *     IsActive, not crowd, IsAggressive, not scene-blocked,
 *     record has objectActions, one of them PuppetQuickHack,
 *     and the attacker holds a cyberdeck
 *
 * They look like separate problems and turn out to share one answer.
 *
 * WHAT ACTUALLY DOES IT: a hostile attitude toward the other player.
 *
 * Hostility satisfies Att_Hostile for the weapon filter directly, and it is also the fourth
 * route to IsAggressive() - so it clears the quickhack gate at the same time. Measured
 * before and after on a live muppet:
 *
 *     before hostile:  IsQuickHackAble false   IsAggressive false   cannot aim
 *     after  hostile:  IsQuickHackAble true    IsAggressive true    can aim
 *
 * The other half is the record: MaMuppet and WaMuppet carry objectActions now (see
 * CyberpunkMP.tweak). Attitude alone is not enough - a puppet with no object actions fails
 * condition 5 whatever its attitude.
 *
 * WHAT WAS TRIED AND DISCARDED. The GameplayRestriction.FistFight status effect is the
 * first branch of IsAggressive() and looked like the least invasive route - no AI change,
 * no hostility. It did not work: IsAggressive stayed false after applying it, and it does
 * nothing for weapon targeting either, which needs Att_Hostile specifically rather than
 * aggression. Attitude replaced it.
 *
 * THE COST, and it is a real one. Hostility is what police, prevention and NPC AI react to.
 * Every player becoming an enemy NPC in every other player's game is what makes native
 * combat work, and it may also make bystanders and the prevention system treat them as
 * threats. Scoped as narrowly as the API allows - hostility is set toward the LOCAL PLAYER
 * only, per puppet, not by changing anyone's faction - but that is a narrowing, not an
 * elimination. This stays behind a flag until it has been played with rather than tested.
 */
public func MpTryMakeHackable(entity: ref<GameObject>) -> Void {
    if !IsDefined(entity) {
        return;
    }

    let network = GameInstance.GetNetworkWorldSystem();
    if !IsDefined(network) || !network.HackablePuppetsEnabled() {
        return;
    }

    // Only our puppets. Anything else reaching here is a mistake not worth compounding by
    // making a random NPC hostile.
    if !entity.HasTag(n"CyberpunkMP.Puppet") {
        return;
    }

    let player = GetPlayer(GetGameInstance());
    if !IsDefined(player) {
        return;
    }

    let theirs = entity.GetAttitudeAgent();
    let mine = player.GetAttitudeAgent();

    if !IsDefined(theirs) || !IsDefined(mine) {
        MpFTLogWarning(s"[Hackable] no attitude agent on \(EntityID.GetHash(entity.GetEntityID())) - it will not be targetable");
        return;
    }

    // NEUTRAL, no longer hostile. Hostility made the NPC AI fight: shot at, a remote player's
    // puppet went Combat and the AI drove it for seconds at a time, and the lab walker - armed
    // and hostile - downed its player twice while the Relaxed lock watched. Shots no longer
    // need it either: they land on the hitbox (MpSetupHitbox), and the game damages a neutral
    // NPC the way it damages a pedestrian. The cost is the red reticle, smart-weapon locks and
    // quickhacks, which all gate on hostility - noted, not solved.
    // Not friendly either: the game does not let the player damage a friendly NPC, and the
    // muppet and hitbox records inherit Panam's companion attitude.
    theirs.SetAttitudeTowards(mine, EAIAttitude.AIA_Neutral);

    MpFTLog(s"[Hackable] \(EntityID.GetHash(entity.GetEntityID())) set neutral toward us");
}

/**
 * Remote players must be damageable - the runtime half of the Panam god-mode fix.
 *
 * The muppet records inherit from Character.Panam, and the game grants NPC god mode from
 * record tags when the puppet initialises (NPCManager.SetNPCImmortalityMode, source
 * 'Default'). An Invulnerable puppet absorbs every shot before Combat.reds can report it.
 * CyberpunkMP.tweak strips the tags; this is the backstop in case that does not take, and
 * the proof either way - it LOGS which god modes were on the puppet and from what source,
 * because TweakDB tags are hashed and cannot be read offline. No log line saying "had god
 * mode" on a fresh session means the tweak did its job.
 *
 * Independent of -no-hackable-puppets on purpose. That switch is about hostility, which
 * other systems react to; a remote player being unkillable is never correct.
 *
 * Checked twice: once at attach, and again a moment later, because NPCManager runs from
 * OnPostInitialize and nothing guarantees that has happened before OnEntityAttached. The
 * game never re-applies it after init, so a clear that lands after it sticks.
 *
 * Only the 'Default' source is cleared - the one the record grants. Anything else holding
 * god mode on a puppet is logged and left alone, because it would be something to find,
 * not something to paper over.
 */
/**
 * Keep remote players out of the game's own combat AI.
 *
 * The hostility above is what makes a puppet a target, and it is also what the NPC AI reacts
 * to: shot at, the puppet went Combat, the engine swapped our movement controller out
 * (MultiMovement "Detach") and for ~18 seconds the AI moved it - it took cover and acted
 * like an enemy while the real player stood somewhere else. Relaxed is the state our
 * controller is attached in, so any other state is sent straight back there.
 */
@addField(ScriptedPuppet)
public let m_mpRelaxCount: Int32;

// The event lives on the reaction manager, not the puppet (probed against 2.5's scripts:
// ScriptedPuppet, NPCPuppet, NPCStatesComponent and AIHumanComponent have no such method).
@wrapMethod(ReactionManagerComponent)
protected cb func OnHighLevelStateDataEvent(evt: ref<gameHighLevelStateDataEvent>) -> Bool {
    let result = wrappedMethod(evt);

    let puppet = this.GetOwner() as ScriptedPuppet;

    if IsDefined(puppet) && puppet.HasTag(n"CyberpunkMP.Puppet")
        && NotEquals(evt.currentHighLevelState, gamedataNPCHighLevelState.Relaxed) {
        puppet.m_mpRelaxCount += 1;

        // First few only: if the AI keeps fighting it, the count says so without a wall.
        if puppet.m_mpRelaxCount <= 5 {
            MpFTLog(s"[Hackable] \(EntityID.GetHash(puppet.GetEntityID())) AI went to state \(EnumInt(evt.currentHighLevelState)) - forcing Relaxed (\(puppet.m_mpRelaxCount))");
        }

        NPCPuppet.ChangeHighLevelState(puppet, gamedataNPCHighLevelState.Relaxed);
    }

    return result;
}

/**
 * Every component on an entity, by class, with the disabled ones marked.
 *
 * Shots and punches pass straight through remote players without a single hit event (not
 * even the [HitShape] line every NPC hit produces), so the puppet is missing something an
 * NPC has. Logged for a remote puppet when it attaches and for the first ordinary NPC that
 * gets hit, the two lists say what.
 */
public func MpDumpComponents(entity: ref<Entity>, label: String) -> Void {
    if !IsDefined(entity) {
        return;
    }

    let components = entity.GetComponents();
    let names = "";
    let i = 0;
    while i < ArraySize(components) {
        if IsDefined(components[i]) {
            names += NameToString(components[i].GetClassName());
            if !components[i].IsEnabled() {
                names += "(off)";
            }
            names += " ";
        }
        i += 1;
    }

    MpFTLog(s"[Components] \(label): \(ArraySize(components)) - \(names)");
}

@addField(PlayerPuppet)
public let m_mpNpcComponentsDumped: Bool;

/**
 * The hitbox: an invisible real-NPC body the server keeps at a player-body puppet's
 * position, because shots pass straight through the player's cutscene body. Recognised by
 * its record; everything that lands on it the server hands to the puppet's owner.
 */
public func MpIsHitbox(entity: ref<GameObject>) -> Bool {
    let puppet = entity as ScriptedPuppet;
    return IsDefined(puppet) && Equals(puppet.GetRecordID(), t"Character.MpHitbox");
}

public func MpSetupHitbox(entity: ref<GameObject>) -> Void {
    if !IsDefined(entity) {
        return;
    }

    // Every mesh off, so nothing draws; the hit representation is not a mesh and stays.
    let components = entity.GetComponents();
    let hidden = 0;
    let i = 0;
    while i < ArraySize(components) {
        if IsDefined(components[i]) && StrContains(NameToString(components[i].GetClassName()), "Mesh") {
            components[i].Toggle(false);
            hidden += 1;
        }
        i += 1;
    }

    MpFTLog(s"[Hitbox] \(EntityID.GetHash(entity.GetEntityID())) set up - \(hidden) mesh component(s) hidden");
}

public static func MpGodModeRecheckSeconds() -> Float = 1.0

public func MpStripInheritedGodMode(entity: ref<GameObject>) -> Void {
    if !IsDefined(entity) || !entity.HasTag(n"CyberpunkMP.Puppet") {
        return;
    }

    MpClearRecordGodMode(entity, "attach");

    // Immortal, from our own source: hits still land and still get reported (Combat.reds),
    // but this machine can no longer kill the puppet on its own. Whether a remote player is
    // down is the server's call, drawn by MpApplyRemoteLifeStates.
    GameInstance.GetGodModeSystem(entity.GetGame())
        .AddGodMode(entity.GetEntityID(), gameGodModeType.Immortal, n"CyberpunkMP.RemotePuppet");

    let recheck = new MpGodModeRecheckCallback();
    recheck.entity = entity;
    GameInstance.GetDelaySystem(entity.GetGame()).DelayCallback(recheck, MpGodModeRecheckSeconds(), false);
}

public func MpClearRecordGodMode(entity: ref<GameObject>, when: String) -> Void {
    let gods = GameInstance.GetGodModeSystem(entity.GetGame());
    let id = entity.GetEntityID();

    let invulnerable = gods.GetGodModeSources(id, gameGodModeType.Invulnerable);
    let immortal = gods.GetGodModeSources(id, gameGodModeType.Immortal);

    if ArraySize(invulnerable) == 0 && ArraySize(immortal) == 0 {
        MpFTLog(s"[Hackable] \(when): \(EntityID.GetHash(id)) has no god mode - damageable");
        return;
    }

    MpFTLogWarning(s"[Hackable] \(when): \(EntityID.GetHash(id)) had god mode - Invulnerable from [\(MpJoinNames(invulnerable))], Immortal from [\(MpJoinNames(immortal))] - clearing 'Default'");
    gods.ClearGodMode(id, n"Default");
}

public func MpJoinNames(names: array<CName>) -> String {
    let joined = "";
    let i = 0;
    while i < ArraySize(names) {
        if i > 0 {
            joined += ", ";
        }
        joined += NameToString(names[i]);
        i += 1;
    }
    return joined;
}

public class MpGodModeRecheckCallback extends DelayCallback {
    public let entity: wref<GameObject>;

    public func Call() -> Void {
        if !IsDefined(this.entity) {
            return;
        }
        MpClearRecordGodMode(this.entity, "recheck");
        MpDumpComponents(this.entity, s"remote puppet \(EntityID.GetHash(this.entity.GetEntityID()))");

        // Appearance work can switch meshes back on after attach; a hitbox stays hidden.
        if MpIsHitbox(this.entity) {
            MpSetupHitbox(this.entity);
        }

        // Streamed in while already down: draw it that way.
        let network = GameInstance.GetNetworkWorldSystem();
        if IsDefined(network) {
            let serverId = network.GetServerIdByEntity(this.entity.GetEntityID());
            let state = network.GetRemoteLifeState(serverId);
            if NotEquals(serverId, 0ul) && NotEquals(state, 0u) {
                MpDrawRemoteLifeState(network, serverId, state);
            }
        }
    }
}
