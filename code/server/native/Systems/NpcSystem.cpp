#include "NpcSystem.h"
#include "Game/World.h"
#include "Game/Level.h"

#include "Components/MovementComponent.h"
#include "Components/AppearanceComponent.h"
#include "Components/NpcComponent.h"
#include "Components/PlayerComponent.h"
#include "Components/HealthComponent.h"
#include "GameServer.h"

#include "Core/Filesystem.h"

#include <fstream>
#include <nlohmann/json.hpp>

using nlohmann::json;

NpcSystem::NpcSystem(gsl::not_null<World*> apWorld)
    : m_pWorld(apWorld)
    , m_statePath(GetPath() / "config" / "npcs.json")
{
    Load();

    std::error_code ec;
    m_walkerEnabled = std::filesystem::exists(GetPath() / "config" / "walker.on", ec);
    if (m_walkerEnabled)
        spdlog::warn("[Walker] config/walker.on found - a debug walker will circle the first player to spawn");
}

void NpcSystem::UpdateWalker(std::chrono::steady_clock::time_point aNow) noexcept
{
    if (!m_walkerEnabled)
        return;

    // A player's client sends at 30/s; so does this.
    if (aNow - m_walkerLastStep < std::chrono::milliseconds(33))
        return;
    m_walkerLastStep = aNow;

    if (!m_walker || !m_walker.is_alive())
    {
        m_walker = flecs::entity{};

        const MovementComponent* pAnchor = nullptr;
        m_pWorld->each(
            [&pAnchor](flecs::entity, const PlayerComponent& aPlayer)
            {
                if (pAnchor || !aPlayer.Puppet || !aPlayer.Puppet.is_alive())
                    return;
                if (const auto* pMovement = aPlayer.Puppet.get<MovementComponent>(); pMovement && pMovement->Tick != 0)
                    pAnchor = pMovement;
            });

        if (!pAnchor)
        {
            m_playerFirstSeen = {};
            return;
        }

        // Give the player's world time to finish loading before anything spawns next to it.
        if (m_playerFirstSeen == std::chrono::steady_clock::time_point{})
            m_playerFirstSeen = aNow;
        if (aNow - m_playerFirstSeen < std::chrono::seconds(15))
            return;

        // Round the player rather than beside them: interiors are cramped, and a circle
        // centred 5m away put half the lap inside a wall.
        m_walkerCenter = pAnchor->Position;
        m_walkerStart = aNow;
        // Where the lap starts (angle 0), not on top of the player.
        m_walker = Spawn("Character.WaMuppet", "Walker", m_walkerCenter + glm::vec3{2.f, 0.f, 0.f}, 0.f);
        if (auto* pNpc = m_walker.get_mut<NpcComponent>())
            pNpc->Transient = true;
        m_walker.set<HealthComponent>({});

        spdlog::warn("[Walker] spawned 5m from the player at ({:.1f}, {:.1f}, {:.1f})", m_walkerCenter.x,
                     m_walkerCenter.y, m_walkerCenter.z);
        return;
    }

    const auto* pCurrent = m_walker.get<MovementComponent>();
    if (!pCurrent)
        return;

    // A combatant like any player, so PvP can be tested by one person: shot down, it stays
    // down (and still) for ten seconds and then stands back up, broadcasting both changes
    // exactly as a revive does.
    if (auto* pHealth = m_walker.get_mut<HealthComponent>(); pHealth && pHealth->LifeState != 0)
    {
        if (m_walkerDownSince == std::chrono::steady_clock::time_point{})
        {
            m_walkerDownSince = aNow;
            spdlog::warn("[Walker] downed - standing back up in 10s");
        }

        if (aNow - m_walkerDownSince < std::chrono::seconds(10))
            return;

        pHealth->Health = pHealth->MaxHealth;
        pHealth->LifeState = 0;
        pHealth->DownedAt = 0;
        m_walkerDownSince = {};

        if (auto* pLevel = m_pWorld->get_mut<Level>())
            pLevel->BroadcastCombatState(m_walker);

        spdlog::warn("[Walker] back up");
    }

    // Draws and holsters a pistol every six seconds, sent the way the server relays a
    // player's own weapon events, so remote weapons can be checked without a second player.
    if (aNow - m_walkerLastWeaponToggle >= std::chrono::seconds(6))
    {
        m_walkerLastWeaponToggle = aNow;
        m_walkerArmed = !m_walkerArmed;

        constexpr uint64_t kLexington = 129218226825ull; // Items.Preset_Lexington_Default

        server::NotifyWeaponEvent event;
        event.set_id(m_walker.id());
        event.set_kind(m_walkerArmed ? 0u : 1u);
        event.set_weapon_id(m_walkerArmed ? kLexington : 0ull);

        m_pWorld->each([&event](flecs::entity, const PlayerComponent& aPlayer)
                       { GServer->Send(aPlayer.Connection, event); });

        spdlog::warn("[Walker] {} its pistol", m_walkerArmed ? "drew" : "holstered");
    }

    // Walking pace round a 2m circle: one lap every ~9s. The first three seconds stand
    // still, so the client has spawned it before it starts moving.
    constexpr float kRadius = 2.f;
    constexpr float kSpeed = 1.4f;
    const float elapsed = std::chrono::duration<float>(aNow - m_walkerStart).count() - 3.f;
    if (elapsed < 0.f)
        return;

    const float angle = elapsed * kSpeed / kRadius;

    auto movement = *pCurrent;
    movement.Position = m_walkerCenter + glm::vec3{kRadius * std::cos(angle), kRadius * std::sin(angle), 0.f};
    // Facing along the circle: the game's yaw 0 looks down +Y, and the tangent at this angle
    // is (-sin, cos), which is exactly yaw = angle.
    movement.Rotation = {0.f, 0.f, angle};
    movement.Velocity = kSpeed;
    // The clock clients synchronise to (Server::GetTick), which is what a player's client
    // stamps its own packets with - not wall-clock epoch time.
    movement.Tick = GServer ? GServer->GetTick() : 0;
    ++movement.Sequence;

    // set<> fires the replication observer, exactly as an accepted player packet does.
    m_walker.set<MovementComponent>(movement);

    static auto s_lastReport = aNow;
    if (aNow - s_lastReport >= std::chrono::seconds(5))
    {
        s_lastReport = aNow;
        spdlog::warn("[Walker] step {} at ({:.1f}, {:.1f}), tick {}, replicated {} time(s) so far", movement.Sequence,
                     movement.Position.x, movement.Position.y, movement.Tick,
                     m_walker.get<MovementComponent>()->ReplicatedSequence);
    }
}

flecs::entity NpcSystem::Spawn(const std::string& acRecord, const std::string& acName,
                               const glm::vec3& acPosition, float aYaw) noexcept
{
    auto entity = m_pWorld->entity()
                      .set<MovementComponent>({acPosition, {0.f, 0.f, aYaw}, {}})
                      .set<AppearanceComponent>({})
                      .set<NpcComponent>({acRecord, acName});

    // The same door players walk through: Add tags it as a level actor, broadcasts the
    // load to everyone online, and the join-time sweep hands it to everyone who comes
    // later. One declaration, many renderers.
    if (auto* pLevel = m_pWorld->get_mut<Level>())
        pLevel->Add(entity);

    spdlog::info("NPC '{}' ({}) declared at ({:.1f}, {:.1f}, {:.1f})", acName, acRecord,
                 acPosition.x, acPosition.y, acPosition.z);

    return entity;
}

size_t NpcSystem::Clear() noexcept
{
    Vector<flecs::entity> npcs;

    m_pWorld->each([&npcs](flecs::entity aEntity, const NpcComponent&) { npcs.push_back(aEntity); });

    auto* pLevel = m_pWorld->get_mut<Level>();
    for (auto npc : npcs)
    {
        if (pLevel)
            pLevel->Remove(npc); // broadcasts the unload, then destructs
    }

    Save();

    return npcs.size();
}

size_t NpcSystem::Count() const noexcept
{
    size_t count = 0;
    m_pWorld->each([&count](flecs::entity, const NpcComponent&) { ++count; });
    return count;
}

void NpcSystem::Save() noexcept
{
    try
    {
        json list = json::array();

        m_pWorld->each(
            [&list](flecs::entity aEntity, const NpcComponent& aNpc)
            {
                if (aNpc.Transient)
                    return;

                const auto* pMovement = aEntity.get<MovementComponent>();
                if (!pMovement)
                    return;

                list.push_back({
                    {"record", aNpc.Record},
                    {"name", aNpc.Name},
                    {"x", pMovement->Position.x},
                    {"y", pMovement->Position.y},
                    {"z", pMovement->Position.z},
                    {"yaw", pMovement->Rotation.z},
                });
            });

        std::ofstream file(m_statePath);
        file << list.dump(2);
    }
    catch (const std::exception& e)
    {
        spdlog::warn("could not save npcs.json: {}", e.what());
    }
}

void NpcSystem::Load() noexcept
{
    try
    {
        std::ifstream file(m_statePath);
        if (!file.is_open())
            return; // no NPCs declared yet

        const auto list = json::parse(file);
        for (const auto& entry : list)
        {
            Spawn(entry.value("record", std::string{}), entry.value("name", std::string{"NPC"}),
                  {entry.value("x", 0.f), entry.value("y", 0.f), entry.value("z", 0.f)},
                  entry.value("yaw", 0.f));
        }

        if (!list.empty())
            spdlog::info("{} persistent NPC(s) restored", list.size());
    }
    catch (const std::exception& e)
    {
        spdlog::warn("npcs.json unreadable ({}) - no NPCs restored", e.what());
    }
}
