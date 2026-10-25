module CyberpunkMP

import CyberpunkMP.World.*

/**
 * Stage 6 - hit synchronisation. The client half that was missing.
 *
 * Stages 1 to 5 built the protocol, the server validation, server-owned health and
 * server-owned ammunition, and nothing ever sent an event, because nothing detected one. A
 * remote player was not a target the engine would accept, so no hit could occur to report.
 * That is fixed (see Hackable.reds), and this is the piece that connects the two.
 *
 * INTERCEPT, DO NOT REPLACE. The brief is explicit and it is right: Cyberpunk already
 * computes attacker, target, weapon, damage, damage type, hit position, direction and
 * whether it crit. Rebuilding any of that server-side would be months of work that drifted
 * from the game every patch. gameHitEvent carries all of it, so the whole job here is to
 * notice and report.
 *
 * WHAT THIS DOES NOT DO. It does not apply damage, block the hit, or decide anything. The
 * local engine carries on exactly as it would have; what is sent is a CLAIM, and the
 * authoritative answer arrives separately as NotifyDamageResult. A client that applied its
 * own damage would be the "fake damage packet" architecture the brief warns against.
 *
 * ONLY OUR OWN ATTACKS, and only against our own puppets. Every NPC in Night City runs
 * through this hook; the two guards below are what keep it from becoming a firehose.
 */

// gamedataStatPoolType.Health is what a weapon spends. Named here so the intent survives.
//
// DamagePipelineFinalized, not OnHit. On 2.5 OnHit arrives before the damage pipeline has run
// and evt.attackComputed is null there, so every hit on a remote player reported 0 damage and
// stopped at the damage <= 0 check. This runs once the engine has computed the attack - the
// same hook VehicleDamageProbe has always read correct values from - and before it is applied.
@wrapMethod(NPCPuppet)
protected func DamagePipelineFinalized(evt: ref<gameHitEvent>) -> Void {
    MpReportHit(this, evt);

    // Always chain. Suppressing the game's own handling would cost the hit reaction, the
    // blood, the impact sound and the stagger - and we would then have to rebuild them.
    wrappedMethod(evt);
}

/**
 * Tell the server that the local player just hit a remote player.
 *
 * Silent about everything else on purpose. This runs for every NPC hit in the game.
 */
public func MpReportHit(target: ref<ScriptedPuppet>, evt: ref<gameHitEvent>) -> Void {
    if !IsDefined(target) || !IsDefined(evt) {
        return;
    }

    // HIT SHAPE NAMES, logged for ANY target including ordinary NPCs.
    //
    // Deliberately before every guard below. The body-part vocabulary lives in a
    // gameHitShapeBVH asset that cannot be read statically, so the only way to learn it is
    // from a live hit - and putting this after the "is it one of ours" check would mean it
    // could only ever be learned with a second player online. Shooting any NPC in Night City
    // answers it alone.
    //
    // Costs one log line per hit and nothing else; it is removed once the names are known.
    if ArraySize(evt.hitRepresentationResult.hitShapes) > 0 {
        let probe = evt.hitRepresentationResult.hitShapes[0];

        MpFTLog(s"[HitShape] '\(NameToString(probe.hitShapeName))' material '\(NameToString(probe.physicsMaterial))'");
    }

    let network = GameInstance.GetNetworkWorldSystem();
    if !IsDefined(network) || !network.IsConnected() {
        return;
    }

    // Is the thing that got hit one of ours? Zero means an ordinary NPC, which is the
    // common case rather than an error.
    let targetId = network.GetServerIdByEntity(target.GetEntityID());
    if Equals(targetId, 0ul) {
        // One ordinary NPC's components, to compare against a remote puppet's.
        let me = GetPlayer(GetGameInstance());
        if IsDefined(me) && !me.m_mpNpcComponentsDumped && !target.HasTag(n"CyberpunkMP.Puppet") {
            me.m_mpNpcComponentsDumped = true;
            MpDumpComponents(target, s"hit NPC \(NameToString(target.GetClassName()))");
        }

        if target.HasTag(n"CyberpunkMP.Puppet") {
            MpFTLog(s"[Combat] hit on remote puppet \(EntityID.GetHash(target.GetEntityID())) dropped - no server id for it");
        }
        return;
    }

    // Did WE do it? Every client sees the same puppets, and without this every observer
    // would report the same shot - the server would then have to work out which of five
    // identical claims was real.
    let instigator = evt.attackData.GetInstigator();
    let player = GetPlayer(GetGameInstance());

    if !IsDefined(instigator) || !IsDefined(player) {
        MpFTLog(s"[Combat] hit on remote \(targetId) dropped - no instigator");
        return;
    }

    if NotEquals(instigator.GetEntityID(), player.GetEntityID()) {
        MpFTLog(s"[Combat] hit on remote \(targetId) dropped - not ours (instigator \(EntityID.GetHash(instigator.GetEntityID())))");
        return;
    }

    // What the engine computed. Health is the pool a weapon actually spends; armour and
    // resistances have already been applied by this point, which is precisely why taking
    // the game's number is better than recomputing it.
    let damage: Float = 0.0;
    let damageType: Int32 = 0;

    if IsDefined(evt.attackComputed) {
        damage = evt.attackComputed.GetTotalAttackValue(gamedataStatPoolType.Health);
        damageType = EnumInt(evt.attackComputed.GetDominatingDamageType());
    }

    // A hit that did nothing is not worth a packet. Grazes, blocked shots and the second
    // half of a piercing round all land here.
    if damage <= 0.0 {
        MpFTLog(s"[Combat] hit on remote \(targetId) dropped - computed \(damage) health damage (attackComputed defined: \(IsDefined(evt.attackComputed)))");
        return;
    }

    // As a share of a PLAYER's health. The server's pool is 0..100 and the raw figure is in hit
    // points: unscaled, one punch (172) downed a player outright; scaled by the hitbox's own
    // pool it took ~450 shots, because the hitbox is Panam and she has 46,800. Our own maximum
    // is the yardstick instead - what this hit would take from someone like us - which is fair
    // while players are of a similar level.
    let maxHealth = GameInstance.GetStatPoolsSystem(target.GetGame())
        .GetStatPoolMaxPointValue(Cast<StatsObjectID>(player.GetEntityID()), gamedataStatPoolType.Health);
    let raw = damage;
    if maxHealth > 0.0 {
        damage = raw * 100.0 / maxHealth;
    }

    MpFTLog(s"[Combat] reporting \(damage)% (\(raw) of \(maxHealth)) on remote \(targetId)");

    // HIT ZONE, read from the game rather than invented.
    //
    // gameHitEvent carries hitRepresentationResult.hitShapes, and each HitShapeData has a
    // hitShapeName CName - which IS the body part. That is the native representation; there
    // is no enum to map onto and no numbering of our own to invent.
    //
    // The names themselves live in the entity's hit-representation asset (a gameHitShapeBVH
    // the .ent only references), so they cannot be read out of the template - the .ent
    // stores "None" placeholders. They CAN be read off a live hit, which is what this line
    // is for: shoot a native NPC, read the name out of the log, and the real vocabulary is
    // known rather than guessed.
    //
    // Until then the zone travels as the CName's own hash, which is lossless. A receiver
    // that does not recognise a hash plays a generic reaction, which is exactly the current
    // behaviour - so this is strictly better than zero and involves no guessing.
    let hitZone: Uint32 = 0u;

    if ArraySize(evt.hitRepresentationResult.hitShapes) > 0 {
        let shape = evt.hitRepresentationResult.hitShapes[0];

        // Truncated to 32 bits. A CName is a 64-bit hash and the field is Uint32, so this
        // is a lossy identifier - fine for "which of a handful of body parts", and it is
        // the same value on every machine, which is what matters.
        // 4294967295, not 0xFFFFFFFF - redscript has no hex literals, and the hex form is a
        // syntax error that takes EVERY script in the mod down with it rather than failing
        // locally. That is what the "REDScript compilation has failed - Combat.reds" dialog
        // was.
        hitZone = Cast<Uint32>(NameToHash(shape.hitShapeName) & 4294967295ul);
    }

    // Ranged unless the attack data says otherwise. The distinction that matters to the
    // receiver is which reaction to play, and melee reads differently from a bullet.
    let sourceType: Uint32 = 0u;
    let attackType: Uint32 = 0u;

    if Equals(evt.attackData.GetAttackType(), gamedataAttackType.Melee) {
        sourceType = 1u;
        attackType = 1u;
    }

    // Which weapon, when there is one. Zero for fists and for anything that does not
    // present a record.
    let sourceId: Uint64 = 0ul;
    let weapon = evt.attackData.GetWeapon();

    if IsDefined(weapon) {
        sourceId = TDBID.ToNumber(weapon.GetWeaponRecord().GetID());
    }

    network.SendCombatEvent(
        targetId,
        sourceType,
        attackType,
        sourceId,
        Cast<Uint32>(damageType),
        hitZone,
        damage,
        evt.hitPosition,
        evt.hitDirection,
        false,                   // crit
        false);                  // headshot

    // The claim is sent; the puppet's own health pool is ours to keep full. The server owns
    // the real number, and a local pool run dry is how a puppet dies on one screen only.
    let refill = new MpRefillPuppetHealthCallback();
    refill.puppet = target;
    GameInstance.GetDelaySystem(target.GetGame()).DelayCallback(refill, 0.1, false);
}

/**
 * A takedown the engine expressed as a knock-out rather than as damage - landing on
 * somebody's head is one. Reported as a full-pool melee hit, which the server clamps to
 * exactly what downs a player and nothing more.
 */
public func MpReportTakedown(network: ref<NetworkWorldSystem>, target: ref<ScriptedPuppet>, targetId: Uint64) -> Void {
    network.SendCombatEvent(
        targetId,
        1u,                      // melee
        1u,                      // melee
        0ul,
        0u,
        0u,
        100.0,
        target.GetWorldPosition(),
        new Vector4(0.0, 0.0, 0.0, 0.0),
        false,
        false);

    MpFTLog(s"[Combat] knocked remote entity \(targetId) out - reported as a takedown");
}

public class MpRefillPuppetHealthCallback extends DelayCallback {
    public let puppet: wref<ScriptedPuppet>;

    public func Call() -> Void {
        if !IsDefined(this.puppet) {
            return;
        }

        GameInstance.GetStatPoolsSystem(this.puppet.GetGame()).RequestSettingStatPoolValue(
            Cast<StatsObjectID>(this.puppet.GetEntityID()), gamedataStatPoolType.Health, 100.0, null, false);
    }
}

/**
 * Set by MpDrawRemoteLifeState while the server has this puppet down, so the guard in
 * MpReportStatusEffect knows the Defeated on it is the server's and leaves it alone.
 */
@addField(ScriptedPuppet)
public let m_mpServerDowned: Bool;

/**
 * Draw other players down or back up, as the server says.
 *
 * The same Defeated the victim's own game applies to them (MpApplyDownedState), put on the
 * puppet that stands for them here - so everyone sees the one state the server holds.
 */
/**
 * Other players' weapons, in their puppets' hands.
 *
 * MpPollWeapon has always told the server when we draw, holster and fire, and the server has
 * always relayed it - but nothing received it, so on every other screen a player's weapon
 * stayed holstered whatever they did. This puts the weapon they drew in the puppet's right
 * hand and takes it away when they holster.
 */
@addField(ScriptedPuppet)
public let m_mpHeldWeapon: Uint64;

public func MpApplyRemoteWeapons(network: ref<NetworkWorldSystem>) -> Void {
    let serverId = network.ConsumeRemoteWeaponEvent();

    while NotEquals(serverId, 0ul) {
        MpDrawRemoteWeapon(network, serverId, network.GetConsumedWeaponKind(), network.GetConsumedWeaponId());
        serverId = network.ConsumeRemoteWeaponEvent();
    }
}

public func MpDrawRemoteWeapon(network: ref<NetworkWorldSystem>, serverId: Uint64, kind: Uint32, weaponId: Uint64) -> Void {
    let entityId = network.GetEntityIdByServerId(serverId);
    if !EntityID.IsDefined(entityId) {
        return;
    }

    let puppet = GameInstance.FindEntityByID(GetGameInstance(), entityId) as ScriptedPuppet;
    if !IsDefined(puppet) {
        return;
    }

    let transactions = GameInstance.GetTransactionSystem(puppet.GetGame());
    let slot = t"AttachmentSlots.WeaponRight";

    if Equals(kind, 1u) || Equals(weaponId, 0ul) {
        if NotEquals(puppet.m_mpHeldWeapon, 0ul) {
            transactions.RemoveItemFromSlot(puppet, slot);
            puppet.m_mpHeldWeapon = 0ul;
            MpFTLog(s"[Weapon] remote \(serverId) holstered");
        }
        return;
    }

    // A shot from the weapon already in hand changes nothing here.
    if Equals(puppet.m_mpHeldWeapon, weaponId) {
        return;
    }

    let item = ItemID.FromTDBID(network.TdbidFromNumber(weaponId));
    transactions.GiveItem(puppet, item, 1);
    transactions.AddItemToSlot(puppet, slot, item);
    puppet.m_mpHeldWeapon = weaponId;

    MpFTLog(s"[Weapon] remote \(serverId) drew \(weaponId)");
}

public func MpApplyRemoteLifeStates(network: ref<NetworkWorldSystem>) -> Void {
    let serverId = network.ConsumeRemoteLifeChange();

    while NotEquals(serverId, 0ul) {
        MpDrawRemoteLifeState(network, serverId, network.GetConsumedLifeState());
        serverId = network.ConsumeRemoteLifeChange();
    }
}

public func MpDrawRemoteLifeState(network: ref<NetworkWorldSystem>, serverId: Uint64, state: Uint32) -> Void {
    let entityId = network.GetEntityIdByServerId(serverId);
    if !EntityID.IsDefined(entityId) {
        MpFTLog(s"[Combat] entity \(serverId) changed life state but is not spawned here - drawn when it streams in");
        return;
    }

    let puppet = GameInstance.FindEntityByID(GetGameInstance(), entityId) as ScriptedPuppet;
    if !IsDefined(puppet) {
        return;
    }

    if NotEquals(state, 0u) {
        puppet.m_mpServerDowned = true;
        StatusEffectHelper.ApplyStatusEffect(puppet, t"BaseStatusEffect.Defeated");
        MpFTLog(s"[Combat] remote entity \(serverId) is down (state \(state)) - Defeated applied");
        return;
    }

    puppet.m_mpServerDowned = false;
    StatusEffectHelper.RemoveStatusEffect(puppet, t"BaseStatusEffect.Defeated");
    StatusEffectHelper.RemoveStatusEffect(puppet, t"BaseStatusEffect.Unconscious");
    MpFTLog(s"[Combat] remote entity \(serverId) is back up");
}

/**
 * Stage 10 - quickhack status effects, in both directions.
 *
 * Quickhack DAMAGE needs nothing extra: an Overheat burns health through Cyberpunk's
 * ordinary hit pipeline, so the hook above already reports it. What does not travel is the
 * EFFECT - blindness, a weapon glitch, crippled movement. Those are applied to the PUPPET
 * standing on the attacker's machine, and the person actually being hacked never finds out.
 *
 * OUTBOUND: notice an effect landing on one of our puppets and tell the server.
 */
@wrapMethod(ScriptedPuppet)
protected cb func OnStatusEffectApplied(evt: ref<ApplyStatusEffectEvent>) -> Bool {
    MpReportStatusEffect(this, evt);
    return wrappedMethod(evt);
}

public func MpReportStatusEffect(target: ref<ScriptedPuppet>, evt: ref<ApplyStatusEffectEvent>) -> Void {
    if !IsDefined(target) || !IsDefined(evt) || !IsDefined(evt.staticData) {
        return;
    }

    let network = GameInstance.GetNetworkWorldSystem();
    if !IsDefined(network) || !network.IsConnected() {
        return;
    }

    let targetId = network.GetServerIdByEntity(target.GetEntityID());
    if Equals(targetId, 0ul) {
        return;
    }

    let player = GetPlayer(GetGameInstance());
    if !IsDefined(player) || Equals(target.GetEntityID(), player.GetEntityID()) {
        return;
    }

    // Whether a remote player is down is the SERVER's call. Landing on one's head knocked
    // the puppet out on the attacker's machine only (BaseStatusEffect.Unconscious): it lay
    // there for them while the real player walked on. Anything that drops a puppet is taken
    // back off here; a knock-out WE caused becomes a takedown claim, and the server downs
    // them for everyone - this puppet included - through MpApplyRemoteLifeStates.
    let effectId = evt.staticData.GetID();
    let unconscious = Equals(effectId, t"BaseStatusEffect.Unconscious");
    let drops = unconscious || Equals(effectId, t"BaseStatusEffect.Defeated")
        || Equals(effectId, t"BaseStatusEffect.DefeatedWithRecover");

    if drops && !target.m_mpServerDowned {
        StatusEffectHelper.RemoveStatusEffect(target, effectId);
        MpFTLog(s"[Combat] took \(TDBID.ToNumber(effectId)) back off remote entity \(targetId) - only the server downs players");

        if unconscious && Equals(evt.instigatorEntityID, player.GetEntityID()) {
            MpReportTakedown(network, target, targetId);
        }
        return;
    }

    // Only what WE caused. Every client has these puppets, and without this every observer
    // would report the same hack - and the victim would receive it several times over.
    if NotEquals(evt.instigatorEntityID, player.GetEntityID()) {
        return;
    }

    network.SendStatusEffect(
        targetId,
        TDBID.ToNumber(evt.staticData.GetID()),
        evt.stackCount,
        0ul);
}

/**
 * INBOUND: apply what the server says landed on us.
 *
 * On the local PLAYER, not on a puppet - a status effect on a puppet is a status effect on
 * a puppet. This is the only place the hack can actually do anything to the person it was
 * aimed at.
 *
 * Drained on a timer rather than an event because the arrival happens on the network
 * thread; the queue is native, and this is script visiting it.
 */
/**
 * Start (or restart) both polls for this player, superseding any older pair.
 *
 * They used to start only in NetworkWorldSystem.OnConnected. On 2.5 CONNECT happens on the
 * main menu, which is a world of its own: the polls were scheduled on its delay system and
 * died with it when PLAY loaded the real world - so after a normal join nothing sent our
 * weapon, applied the server's health or downs, or drew anyone else's weapon or downed
 * state. Only a reconnect from inside the world brought them back. Now the player's own
 * attach starts them too, and each carries its owner and a token so a superseded pair stops.
 */
@addField(PlayerPuppet)
public let m_mpPollToken: Int32;

public func MpStartPolls(player: ref<PlayerPuppet>) -> Void {
    if !IsDefined(player) {
        return;
    }

    player.m_mpPollToken += 1;

    let status = new MpStatusEffectPoll();
    status.owner = player;
    status.token = player.m_mpPollToken;

    let weapon = new MpWeaponPoll();
    weapon.owner = player;
    weapon.token = player.m_mpPollToken;

    let delays = GameInstance.GetDelaySystem(player.GetGame());
    delays.DelayCallback(status, 0.25, false);
    delays.DelayCallback(weapon, 0.25, false);

    MpFTLog(s"[Combat] polls started (token \(player.m_mpPollToken))");
    MpDumpFireApi(player);
}

/**
 * Once per session: what the game offers for making a remote player's weapon visibly fire.
 *
 * Remote fire events arrive and are ignored - neither player sees the other shoot. The
 * candidates (AIWeapon's static fire functions, FireFXEvent, WeaponObject's fire/shoot/muzzle
 * functions) cannot be read offline with their parameters, so they are written down here.
 */
@addField(PlayerPuppet)
public let m_mpFireApiDumped: Bool;

public func MpDumpFireApi(player: ref<PlayerPuppet>) -> Void {
    if !IsDefined(player) || player.m_mpFireApiDumped {
        return;
    }
    player.m_mpFireApiDumped = true;

    MpDumpFunctions(n"AIWeapon", "", true);
    MpDumpFunctions(n"WeaponObject", "Fire|Shoot|Muzzle|Effect|Burst|Trigger", false);
    MpDumpFunctions(n"gameweaponObject", "Fire|Shoot|Muzzle|Effect|Burst|Trigger", false);

    let props = Reflection.GetClass(n"FireFXEvent").GetProperties();
    let text = "";
    let i = 0;
    while i < ArraySize(props) {
        text += s"\(NameToString(props[i].GetName())): \(NameToString(props[i].GetType().GetName())); ";
        i += 1;
    }
    MpFTLog(s"[FireApi] FireFXEvent { \(text)}");
}

public func MpDumpFunctions(className: CName, filter: String, statics: Bool) -> Void {
    let cls = Reflection.GetClass(className);
    if !IsDefined(cls) {
        MpFTLog(s"[FireApi] no class \(NameToString(className))");
        return;
    }

    let fns: array<ref<ReflectionFunc>>;
    let k = 0;
    if statics {
        let staticFns = cls.GetStaticFunctions();
        while k < ArraySize(staticFns) {
            ArrayPush(fns, staticFns[k]);
            k += 1;
        }
    } else {
        let memberFns = cls.GetFunctions();
        while k < ArraySize(memberFns) {
            ArrayPush(fns, memberFns[k]);
            k += 1;
        }
    }

    let i = 0;
    while i < ArraySize(fns) {
        let name = NameToString(fns[i].GetName());
        if Equals(filter, "") || MpMatchesAny(name, filter) {
            let params = fns[i].GetParameters();
            let text = "";
            let j = 0;
            while j < ArraySize(params) {
                text += s"\(NameToString(params[j].GetName())): \(NameToString(params[j].GetType().GetName())), ";
                j += 1;
            }
            MpFTLog(s"[FireApi] \(NameToString(className)).\(name)(\(text))");
        }
        i += 1;
    }
}

// True when the name contains any of the |-separated words.
public func MpMatchesAny(name: String, words: String) -> Bool {
    let rest = words;
    while StrLen(rest) > 0 {
        let cut = StrFindFirst(rest, "|");
        let word = cut >= 0 ? StrLeft(rest, cut) : rest;
        if StrLen(word) > 0 && StrContains(name, word) {
            return true;
        }
        rest = cut >= 0 ? StrMid(rest, cut + 1) : "";
    }
    return false;
}

public func MpPollIsCurrent(owner: wref<PlayerPuppet>, token: Int32) -> Bool {
    return IsDefined(owner) && Equals(owner.m_mpPollToken, token);
}

public class MpStatusEffectPoll extends DelayCallback {
    public let owner: wref<PlayerPuppet>;
    public let token: Int32;

    public func Call() -> Void {
        // Superseded by a newer pair, or its player is gone with its world.
        if !MpPollIsCurrent(this.owner, this.token) {
            return;
        }

        let network = GameInstance.GetNetworkWorldSystem();

        if !IsDefined(network) {
            return;
        }

        if network.IsConnected() {
            let player = GetPlayer(GetGameInstance());

            if IsDefined(player) {
                // Everything waiting, not just one - two hacks can land inside a frame, and
                // draining one per poll would spread them over half a second.
                let effect = network.ConsumeIncomingStatusEffect();

                while NotEquals(effect, 0ul) {
                    StatusEffectHelper.ApplyStatusEffect(player, network.TdbidFromNumber(effect));
                    MpFTLog(s"[Combat] a quickhack landed on us: \(effect)");

                    effect = network.ConsumeIncomingStatusEffect();
                }

                MpApplyServerHealth(player, network);
                MpApplyDownedState(player, network);
                MpApplyRemoteLifeStates(network);
                MpApplyRemoteWeapons(network);
                MpRehideHitboxes(player as PlayerPuppet);
                MpApplyIncomingUploads(network);
            }
        }

        // Rearmed unconditionally, including while disconnected - the poll has to survive a
        // reconnect, and a callback that stops on the first quiet tick never comes back.
        let again = new MpStatusEffectPoll();
        again.owner = this.owner;
        again.token = this.token;
        GameInstance.GetDelaySystem(GetGameInstance()).DelayCallback(again, 0.25, false);
    }
}

/**
 * Stage 9 - other people can see a quickhack being uploaded.
 *
 * Without this a hack happens in silence: the attacker watches their upload bar, and to
 * everybody else - including the person being hacked - nothing exists until the effect
 * lands. That deletes the one window in which being hacked can be noticed and reacted to,
 * which on a roleplay server is most of the point of hacking somebody.
 *
 * Uses the game's own presentation rather than inventing one. ScriptedPuppet's handler
 * applies AIQuickHackStatusEffect.BeingHacked on STARTED and removes it on COMPLETED - so
 * relaying the transition and running the same two calls gives every client the real
 * visual, and it keeps working if a patch changes what that visual looks like.
 */
@wrapMethod(ScriptedPuppet)
protected cb func OnUploadProgressStateChanged(evt: ref<UploadProgramProgressEvent>) -> Bool {
    MpReportUpload(this, evt);
    return wrappedMethod(evt);
}

public func MpReportUpload(target: ref<ScriptedPuppet>, evt: ref<UploadProgramProgressEvent>) -> Void {
    if !IsDefined(target) || !IsDefined(evt) {
        return;
    }

    // Quickhack uploads only. The same event carries other progress bars, and relaying a
    // device's would put a BeingHacked shimmer on somebody for no reason.
    if NotEquals(evt.progressBarContext, EProgressBarContext.QuickHack)
    || NotEquals(evt.progressBarType, EProgressBarType.UPLOAD) {
        return;
    }

    let network = GameInstance.GetNetworkWorldSystem();
    if !IsDefined(network) || !network.IsConnected() {
        return;
    }

    let targetId = network.GetServerIdByEntity(target.GetEntityID());
    if Equals(targetId, 0ul) {
        return;
    }

    let state: Uint32 = Equals(evt.state, EUploadProgramState.STARTED) ? 0u : 1u;

    network.SendQuickhackUpload(targetId, state, 0ul, evt.duration);

    // THE AUTHORITY REQUEST, on start.
    //
    // Separate from the presentation event above and deliberately so - that one only makes
    // people flicker, this one spends RAM and starts a cooldown. Sent on STARTED rather than
    // COMPLETED because the resource is committed when the upload begins; charging on
    // completion would let somebody start ten hacks and cancel nine for free.
    //
    // Without this the entire RAM pool, cooldown and permission layer on the server was
    // unreachable - built, validated, and never once invoked.
    if Equals(state, 0u) {
        let player = GetPlayer(GetGameInstance());

        if IsDefined(player) {
            // What the game charged us. The server cannot compute this - GetCost() runs
            // against the local StatsSystem with our deck and perks - so it bounds the
            // figure and owns the pool instead. See QuickhackRequest in client.proto.
            let cost = MpCurrentQuickhackCost(player);

            network.SendQuickhackRequest(targetId, MpUploadQuickhackId(evt), cost);
        }
    }
}

/**
 * What the local game says the last quickhack cost, in RAM.
 *
 * Read from the Memory pool rather than from the action, because the action's cost is only
 * available on the ScriptableDeviceAction that ran it and the upload event does not carry
 * one. The difference in the pool across the upload IS what it cost, from the only authority
 * that can compute it.
 *
 * Falls back to a nominal figure when the pool cannot be read, which the server clamps to
 * its floor - erring towards charging something rather than nothing.
 */
public func MpCurrentQuickhackCost(player: ref<GameObject>) -> Float {
    let pools = GameInstance.GetStatPoolsSystem(GetGameInstance());
    let current = pools.GetStatPoolValue(Cast<StatsObjectID>(player.GetEntityID()), gamedataStatPoolType.Memory, false);

    let puppet = player as PlayerPuppet;

    if !IsDefined(puppet) {
        return 4.0;
    }

    // The drop since the last reading. Recorded every upload, so consecutive hacks each
    // measure their own cost rather than accumulating.
    let spent = puppet.m_mpLastRam - current;
    puppet.m_mpLastRam = current;

    if spent <= 0.0 {
        return 4.0;
    }

    return spent;
}

@addField(PlayerPuppet)
public let m_mpLastRam: Float;

/**
 * Which quickhack an upload is for.
 *
 * Answered from the game's own sources rather than a runtime dump: the class definition
 * (gameplayRoleComponent.script) declares the field as a CONCRETE, strongly-typed
 * `var action : ScriptableDeviceAction` - not the varying weak handle it was feared to
 * be - and the vanilla ScriptedPuppet.OnUploadProgressStateChanged calls
 * action.GetObjectActionID() on it in exactly the QuickHack/UPLOAD context our caller
 * has already filtered to. GetObjectActionID() is the hack's TweakDBID (the same id the
 * game itself copies onto spread targets in ActivateIntelligencePerks), and raw TweakDB
 * numbers are already this mod's wire currency for items and weapons.
 *
 * Zero stays the honest fallback for an upload with no action attached - the server
 * refuses an unknown hack, which is the correct outcome for "we could not tell", and
 * visibly different from silently charging the wrong thing.
 */
public func MpUploadQuickhackId(evt: ref<UploadProgramProgressEvent>) -> Uint64 {
    let action = evt.action;
    if !IsDefined(action) {
        return 0ul;
    }

    return TDBID.ToNumber(action.GetObjectActionID());
}

/**
 * Render an upload somebody else started.
 *
 * Applied to the puppet when it is about another player, and to our own player when we are
 * the one being hacked - the same split as status effects, for the same reason.
 */
public func MpApplyIncomingUploads(network: ref<NetworkWorldSystem>) -> Void {
    if !IsDefined(network) {
        return;
    }

    let target = network.ConsumeIncomingUploadTarget();

    while NotEquals(target, 0ul) {
        let state = network.GetIncomingUploadState();

        // The sentinel for "this one is about us" - see ConsumeIncomingUploadTarget.
        let entity: ref<GameObject>;

        if Equals(target, 18446744073709551615ul) {
            entity = GetPlayer(GetGameInstance());
        } else {
            entity = GameInstance.FindEntityByID(GetGameInstance(), EntityID.FromHash(target)) as GameObject;
        }

        if IsDefined(entity) {
            if Equals(state, 0u) {
                StatusEffectHelper.ApplyStatusEffect(entity, t"AIQuickHackStatusEffect.BeingHacked");
            } else {
                StatusEffectHelper.RemoveStatusEffect(entity, t"AIQuickHackStatusEffect.BeingHacked");
            }
        }

        target = network.ConsumeIncomingUploadTarget();
    }
}

/**
 * Stages 4 and 5 - the weapon half, reported by watching state rather than hooking events.
 *
 * The server has owned ammunition since stage 4 and never received a single event, because
 * nothing on this side sent one. The magazine was never decremented, no shot was ever
 * rate-checked and no reload was ever validated - the whole WeaponComponent was unreachable.
 * This is what connects it.
 *
 * WHY A POLL AND NOT HOOKS. Cyberpunk has no clean script-side "weapon fired" event to wrap -
 * the shoot path runs through projectile and animation systems rather than one overridable
 * method. What it does expose is the state itself: GameObject.GetActiveWeapon and
 * WeaponObject.GetMagazineAmmoCount, both static and both cheap.
 *
 * Diffing that state is strictly more reliable than hooking for this purpose. A missed event
 * loses a bullet permanently and the server's count drifts from the player's forever; a
 * missed poll tick is corrected by the next one, because the reading is absolute rather than
 * incremental. For ammunition authority - which is the point - that property matters more
 * than knowing the exact instant a trigger was pulled.
 *
 * Four times a second. Fast enough that a burst is reported as it happens, slow enough to
 * cost nothing.
 */
public class MpWeaponPoll extends DelayCallback {
    public let owner: wref<PlayerPuppet>;
    public let token: Int32;

    public func Call() -> Void {
        if !MpPollIsCurrent(this.owner, this.token) {
            return;
        }

        let network = GameInstance.GetNetworkWorldSystem();

        if IsDefined(network) && network.IsConnected() {
            MpPollWeapon(network);
        }

        // Rearmed unconditionally, so the poll survives a reconnect.
        let again = new MpWeaponPoll();
        again.owner = this.owner;
        again.token = this.token;
        GameInstance.GetDelaySystem(GetGameInstance()).DelayCallback(again, 0.25, false);
    }
}

// Last seen, so a change can be recognised. On the controller rather than in a global
// because redscript has no module state that survives a reload cleanly.
@addField(PlayerPuppet)
public let m_mpLastWeapon: Uint64;

@addField(PlayerPuppet)
public let m_mpLastAmmo: Uint32;

@addField(PlayerPuppet)
public let m_mpWeaponSeen: Bool;

public func MpPollWeapon(network: ref<NetworkWorldSystem>) -> Void {
    let player = GetPlayer(GetGameInstance()) as PlayerPuppet;
    if !IsDefined(player) {
        return;
    }

    let weapon = GameObject.GetActiveWeapon(player);

    // Empty-handed. Reported once, so other clients holster.
    if !IsDefined(weapon) {
        if player.m_mpWeaponSeen && NotEquals(player.m_mpLastWeapon, 0ul) {
            network.SendWeaponEvent(1u, 0ul, 0u, 0u);   // unequip
            player.m_mpLastWeapon = 0ul;
            player.m_mpLastAmmo = 0u;
        }

        player.m_mpWeaponSeen = true;
        return;
    }

    let record = weapon.GetWeaponRecord();
    if !IsDefined(record) {
        return;
    }

    let id = TDBID.ToNumber(record.GetID());
    let ammo = WeaponObject.GetMagazineAmmoCount(weapon);

    // First sighting of the session, or a different weapon in hand.
    if !player.m_mpWeaponSeen || NotEquals(player.m_mpLastWeapon, id) {
        network.SendWeaponEvent(0u, id, ammo, 0u);   // equip

        player.m_mpWeaponSeen = true;
        player.m_mpLastWeapon = id;
        player.m_mpLastAmmo = ammo;
        return;
    }

    if Equals(ammo, player.m_mpLastAmmo) {
        return;
    }

    if ammo < player.m_mpLastAmmo {
        // Rounds left the magazine. One event per round, so the server's fire-rate floor and
        // its count both see every shot rather than one lump that hides a burst.
        // Uint32 throughout - GetMagazineAmmoCount returns Uint32, and mixing it with Int32
        // is what NO_MATCHING_OVERLOAD was complaining about.
        let fired: Uint32 = player.m_mpLastAmmo - ammo;
        let i: Uint32 = 0u;

        while i < fired {
            network.SendWeaponEvent(2u, id, ammo, 0u);   // fire
            i += 1u;
        }
    } else {
        // The magazine grew, which only a reload does. Start and complete together: the poll
        // cannot see the moment it began, and the server validates the pair by the interval
        // between them rather than by trusting either alone.
        network.SendWeaponEvent(3u, id, player.m_mpLastAmmo, 0u);   // reload start
        network.SendWeaponEvent(4u, id, ammo, 0u);                  // reload complete
    }

    player.m_mpLastAmmo = ammo;
}

/**
 * Put the server's verdict on our own health pool.
 *
 * THE HALF THAT MAKES DAMAGE REAL. Everything before this detected hits, validated them,
 * and broadcast a result that nothing applied - the pipeline ran end to end and nobody ever
 * lost a hit point.
 *
 * SET, never subtract. The server sends the health it says we should be on, and applying it
 * absolutely means a dropped packet cannot leave two machines permanently disagreeing.
 * Subtracting a damage figure would also mean recomputing armour locally, which is the
 * thing the whole architecture exists to avoid.
 *
 * Interacts deliberately with Death.reds. The player is Immortal with a floor under their
 * health so the death menu can never open, and that stays true: this writes a value, it
 * does not kill anybody. When the server says we are down, the existing revive machinery is
 * what handles it - the server owns the fact, the client owns the presentation.
 */
public func MpApplyServerHealth(player: ref<PlayerPuppet>, network: ref<NetworkWorldSystem>) -> Void {
    if !IsDefined(player) || !IsDefined(network) {
        return;
    }

    // -1 means the server has said nothing new. Health genuinely reaching zero arrives as
    // a downed state, not as a value we would confuse with "no news".
    let health = network.ConsumeIncomingHealth();
    if health < 0.0 {
        return;
    }

    let pools = GameInstance.GetStatPoolsSystem(player.GetGame());
    let id = Cast<StatsObjectID>(player.GetEntityID());

    // The floor from Death.reds, so a server figure of zero does not fight the immortality
    // that keeps the death menu shut. Being downed is a STATE the server owns; it is not
    // expressed by driving a health pool to nothing.
    let target = MaxF(health, MpDeathFloor());

    pools.RequestSettingStatPoolValue(id, gamedataStatPoolType.Health, target, player, false);

    MpFTLog(s"[Combat] server set our health to \(target)");
}

/**
 * Remembers whether we were down last tick, so the state is edge-triggered.
 *
 * Without this the poll would re-apply Defeated four times a second for as long as somebody
 * lay there, which stacks the effect and makes it survive the revive that removes it once.
 */
@addField(PlayerPuppet)
public let m_mpWasDowned: Bool;

/**
 * Show the player being down when the server says they are down.
 *
 * Cam, 2026-09-04: "/kill doesnt actually down or flatline the player."
 *
 * THE MISSING INCH. The whole chain for this already existed and had done for weeks - the
 * server tracks LifeState, sends it as NotifyCombatState.life_state, the DLL stores it in
 * m_downed and exposes IsDowned() to script - and nothing anywhere ever CALLED IsDowned().
 * Every layer reported success and the player kept standing there, which is why /kill looked
 * like it did nothing rather than like it was half-built. MpApplyServerHealth's own comment
 * promised this ("the server owns the fact, the client owns the presentation"); this is the
 * presentation, finally written.
 *
 * WHY Defeated AND NOT DEATH. Death.reds makes the player Immortal on purpose so the
 * FLATLINED menu can never open - that menu ends the session, which is the thing the medical
 * system exists to replace. So being down is a status effect, not a death: BaseStatusEffect
 * .Defeated is the game's own downed state and what the engine itself applies to a passenger
 * in vehicles.script:825. The player collapses, cannot fight, and is revivable - and the
 * server's bleedout timer decides what happens next.
 *
 * NOT BlockAllMenu. The death flow pairs Defeated with it, and RevivePlayer already has to
 * strip it back off because anyone who kept it had a locked-out pause menu for the rest of
 * the session. Applying it here would recreate that bug on purpose, and Cam asked for the
 * pause menu back the same day.
 */
public func MpApplyDownedState(player: ref<PlayerPuppet>, network: ref<NetworkWorldSystem>) -> Void {
    if !IsDefined(player) || !IsDefined(network) {
        return;
    }

    let downed = network.IsDowned();

    // Bled out: back to the respawn point by ourselves, once. The server only accepts this
    // from dead (ChatSystem::HandleRespawnRequest) and broadcasts us standing.
    if downed && Equals(network.GetOwnLifeState(), 2u) && !player.m_mpRespawnAsked {
        player.m_mpRespawnAsked = true;
        MpShowDownedMessage("YOU BLED OUT - BACK AT THE SPAWN POINT", 5.0);
        network.RequestRespawn();
        network.ScriptLog("combat: bled out - asked the server to respawn us");
    }

    // Edge-triggered. Nothing to do on the ticks where the answer has not changed.
    if Equals(downed, player.m_mpWasDowned) {
        return;
    }

    player.m_mpWasDowned = downed;

    if downed {
        // Defeated alone does nothing visible to the player's own V on 2.5 - Hoka was downed
        // by the server and walked and shot on as if nothing had happened, while everyone
        // else saw him lying where he fell. The gameplay restrictions are what pin him there.
        StatusEffectHelper.ApplyStatusEffect(player, t"BaseStatusEffect.Defeated");
        MpSetDownedRestrictions(player, true);
        MpShowDownedMessage("YOU ARE DOWN - a friend can /revive you", 8.0);
        network.ScriptLog("combat: the server put us down - Defeated and restrictions applied, waiting on a medic");
        return;
    }

    // Back up. RevivePlayer does this too for the case where it drives the recovery itself;
    // doing it here as well covers a revive the server decided on its own, and removing an
    // effect that is not applied is harmless.
    StatusEffectHelper.RemoveStatusEffect(player, t"BaseStatusEffect.Defeated");
    MpSetDownedRestrictions(player, false);
    player.m_mpRespawnAsked = false;
    network.ScriptLog("combat: the server stood us back up");
}

@addField(PlayerPuppet)
public let m_mpRespawnAsked: Bool;

/**
 * What keeps a downed player down: no walking, no fighting, no vehicles. Each record is
 * applied only if this patch has it, and the log says which, so a renamed restriction shows
 * up as a missing line rather than as a player who can still run.
 */
public func MpSetDownedRestrictions(player: ref<PlayerPuppet>, on: Bool) -> Void {
    let restrictions: array<TweakDBID> = [
        t"GameplayRestriction.NoMovement",
        t"GameplayRestriction.NoCombat",
        t"GameplayRestriction.NoJump",
        t"GameplayRestriction.NoSprint",
        t"GameplayRestriction.NoDriving",
        t"GameplayRestriction.VehicleBlock"
    ];

    let applied = "";
    let i = 0;
    while i < ArraySize(restrictions) {
        let id = restrictions[i];
        if IsDefined(TweakDBInterface.GetStatusEffectRecord(id)) {
            if on {
                StatusEffectHelper.ApplyStatusEffect(player, id);
            } else {
                StatusEffectHelper.RemoveStatusEffect(player, id);
            }
            applied += s"\(TDBID.ToNumber(id)) ";
        }
        i += 1;
    }

    MpFTLog(s"[Combat] downed restrictions \(on ? "on" : "off"): \(applied)");
}

public func MpShowDownedMessage(text: String, seconds: Float) -> Void {
    let message: SimpleScreenMessage;
    message.isShown = true;
    message.duration = seconds;
    message.message = text;

    GameInstance.GetBlackboardSystem(GetGameInstance())
        .Get(GetAllBlackboardDefs().UI_Notifications)
        .SetVariant(GetAllBlackboardDefs().UI_Notifications.WarningMessage, ToVariant(message), true);
}

