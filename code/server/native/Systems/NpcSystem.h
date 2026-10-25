#pragma once
#include <string>

struct World;

// Server-declared NPCs: the first "same objects for everyone" increment of the world
// plan (docs/WORLD-STATE.md §3, dynamic server objects). An admin stands somewhere and
// declares a character into existence; every client - present and future - renders the
// same person on the same spot, because the NPC is a server entity broadcast through
// the same machinery as player puppets. Spawns persist in config/npcs.json, owner
// none, no decay: a bartender placed today still tends the bar after every restart.
struct NpcSystem
{
    NpcSystem(gsl::not_null<World*> apWorld);
    NpcSystem(NpcSystem&&) noexcept = default;
    NpcSystem& operator=(NpcSystem&&) noexcept = default;

    // Declare one. Broadcasts to everyone in the world immediately; late joiners get
    // it through the same catch-up sweep that shows them the players already online.
    flecs::entity Spawn(const std::string& acRecord, const std::string& acName, const glm::vec3& acPosition,
                        float aYaw) noexcept;

    // Remove every declared NPC (and forget them). Each removal broadcasts an unload.
    size_t Clear() noexcept;

    size_t Count() const noexcept;

    void Save() noexcept;

    // Debug walker: with config/walker.on present, a mannequin appears beside the first
    // player in the world and walks a circle, sending the same movement a player's client
    // sends. One person can then check remote-puppet movement without a second player.
    void UpdateWalker(std::chrono::steady_clock::time_point aNow) noexcept;

protected:
    void Load() noexcept;

private:
    World* m_pWorld;
    std::filesystem::path m_statePath;

    bool m_walkerEnabled{false};
    flecs::entity m_walker;
    glm::vec3 m_walkerCenter{};
    std::chrono::steady_clock::time_point m_walkerStart{};
    std::chrono::steady_clock::time_point m_walkerLastStep{};
    std::chrono::steady_clock::time_point m_playerFirstSeen{};
};
