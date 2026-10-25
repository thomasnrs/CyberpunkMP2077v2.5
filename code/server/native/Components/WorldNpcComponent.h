#pragma once

// A mirror of an NPC the world host's game is simulating (WorldNpcSystem).
//
// Every machine runs its own city: its own gangers, police and gig targets, each with a
// dynamic EntityID chosen at runtime - measured, not one static id among twenty NPCs hit. So
// nothing can be matched between machines by id. Instead one client, the world host, keeps
// simulating its NPCs as normal and reports the ones near players; each becomes one of these,
// broadcast to everyone else as an NPC built from the same record.
struct WorldNpcComponent
{
    // The host's PLAYER entity - the mirror's parent, so the host is never sent a copy of an
    // NPC it already has.
    flecs::entity Host;

    // The host's own entity hash for the NPC: the key between reports.
    uint64_t LocalId{0};

    // Its character record as a TweakDBID - all the host can read back from TweakDB.
    uint64_t RecordId{0};
};
