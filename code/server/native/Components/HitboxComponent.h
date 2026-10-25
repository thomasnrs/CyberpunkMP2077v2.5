#pragma once

// An invisible NPC body that follows a player-body puppet and takes its hits.
//
// Remote players are built from the player's own cutscene body, because it is the only one
// that accepts the character creator's face and clothes - and shots and punches pass
// straight through it, without even a hit event. A real NPC body registers hits normally, so
// each such puppet gets one of these riding along at its exact position, drawn by nobody.
// Whatever lands on it is the owner's: Level redirects combat and status effects here.
//
// A child of the owner's PLAYER entity (as the puppet is), so the owner is never sent their
// own hitbox - it would stand inside them.
struct HitboxComponent
{
    flecs::entity Owner;
};

// The record every hitbox is built from - see CyberpunkMP.tweak.
inline constexpr const char* kHitboxRecord = "Character.MpHitbox";
