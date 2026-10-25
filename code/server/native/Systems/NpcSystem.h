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
                        float aYaw, const struct AppearanceComponent* apAppearance = nullptr,
                        flecs::entity aParent = {}) noexcept;

    // One invisible NPC-body hitbox per player-body puppet (players, and the walker when it
    // wears a player body), kept at the owner's position. See HitboxComponent.
    void UpdateHitboxes(std::chrono::steady_clock::time_point aNow) noexcept;

    // Remove every declared NPC (and forget them). Each removal broadcasts an unload.
    size_t Clear() noexcept;

    size_t Count() const noexcept;

    void Save() noexcept;

    // Debug walker: with config/walker.on present, a mannequin appears beside the first
    // player in the world and walks a circle, sending the same movement a player's client
    // sends. It also has health (shoot it: it goes down for 10s and gets back up) and draws
    // and holsters a pistol every 6s, so movement, PvP, downed state and remote weapons can
    // all be checked by one person.
    void UpdateWalker(std::chrono::steady_clock::time_point aNow) noexcept;

protected:
    void Load() noexcept;

private:
    World* m_pWorld;
    std::filesystem::path m_statePath;

    std::unordered_map<uint64_t, flecs::entity> m_hitboxes; // owner puppet id -> hitbox
    std::chrono::steady_clock::time_point m_hitboxLastStep{};

    bool m_walkerEnabled{false};
    std::string m_walkerRecord{"Character.WaMuppet"};
    flecs::entity m_walker;
    glm::vec3 m_walkerCenter{};
    std::chrono::steady_clock::time_point m_walkerStart{};
    std::chrono::steady_clock::time_point m_walkerLastStep{};
    std::chrono::steady_clock::time_point m_playerFirstSeen{};
    std::chrono::steady_clock::time_point m_walkerDownSince{};
    std::chrono::steady_clock::time_point m_walkerLastWeaponToggle{};
    bool m_walkerArmed{false};
};
