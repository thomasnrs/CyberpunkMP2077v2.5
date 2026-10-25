#pragma once

#include <unordered_map>

struct World;

// World sync, host model.
//
// Missions and gigs run in each player's own game, against NPCs only that game knows - the
// NPC ids are dynamic and differ per machine, so the same ganger cannot be found on two
// machines by id. One player is the WORLD HOST: their game keeps simulating its NPCs as normal
// and reports the ones near players (WorldNpcReport). Each reported NPC becomes a server
// entity (WorldNpcComponent) broadcast to every other client as an NPC built from the same
// record, moved through the same interpolation as players, and marked dead when it dies.
//
// The host is the first player in the world; when they leave, the next one takes over and
// the old mirrors are removed for the new host to report afresh.
//
// Off unless config/worldnpc.on exists (re-read every few seconds, no restart needed).
// config/npcmirror.echo sends the mirrors to the host as well, so one person can see the
// copies standing beside the originals.
struct WorldNpcSystem
{
    WorldNpcSystem(gsl::not_null<World*> apWorld);
    WorldNpcSystem(WorldNpcSystem&&) noexcept = default;
    WorldNpcSystem& operator=(WorldNpcSystem&&) noexcept = default;

    void Update(std::chrono::steady_clock::time_point aNow) noexcept;

protected:
    void HandleWorldNpcReport(PacketEvent<client::WorldNpcReport>& aMessage) noexcept;

private:
    void ReadSwitches() noexcept;
    void ChooseHost() noexcept;
    void BroadcastHost() noexcept;
    void ClearMirrors() noexcept;

    struct Mirror
    {
        flecs::entity Entity;
        std::chrono::steady_clock::time_point LastSeen;
        uint32_t LifeState{0};
    };

    World* m_pWorld;
    flecs::entity m_host;
    std::unordered_map<uint64_t, Mirror> m_mirrors; // host local id -> mirror
    std::chrono::steady_clock::time_point m_lastHostBroadcast{};
    std::chrono::steady_clock::time_point m_lastSwitchRead{};
    bool m_enabled{false};
    bool m_echo{false};
};
