#include "WorldNpcSystem.h"

#include "Game/World.h"
#include "Game/Level.h"
#include "GameServer.h"
#include "PlayerManager.h"

#include "Components/AppearanceComponent.h"
#include "Components/HealthComponent.h"
#include "Components/MovementComponent.h"
#include "Components/NpcComponent.h"
#include "Components/PlayerComponent.h"
#include "Components/WorldNpcComponent.h"

#include "Core/Filesystem.h"

namespace
{
// A mirror the host has stopped reporting - despawned on their side, or out of range.
constexpr auto kMirrorTimeout = std::chrono::seconds(2);

// Re-sent this often so a player who joins late learns who the host is.
constexpr auto kHostBroadcastInterval = std::chrono::seconds(5);

// Far more than any area a host reports, and few enough that a misbehaving client cannot
// make the server allocate without bound.
constexpr size_t kMaxMirrors = 256;
}

WorldNpcSystem::WorldNpcSystem(gsl::not_null<World*> apWorld)
    : m_pWorld(apWorld)
{
    GServer->RegisterHandler<&WorldNpcSystem::HandleWorldNpcReport>(this);
}

// Off unless config/worldnpc.on exists - checked every few seconds, so it can be switched
// without a restart. Off until guests hide their own NPCs: until then a guest sees their
// city's NPCs AND the host's mirrors. npcmirror.echo the same way.
void WorldNpcSystem::ReadSwitches() noexcept
{
    std::error_code ec;
    const bool enabled = std::filesystem::exists(GetPath() / "config" / "worldnpc.on", ec);
    const bool echo = std::filesystem::exists(GetPath() / "config" / "npcmirror.echo", ec);

    if (enabled != m_enabled)
        spdlog::warn("[WorldNpc] world NPC sync {}", enabled ? "ON (config/worldnpc.on)" : "OFF");
    if (echo != m_echo)
        spdlog::warn("[WorldNpc] echo to the host {}", echo ? "ON (config/npcmirror.echo)" : "OFF");

    // Either change invalidates every mirror: parented or not, wanted or not.
    if (enabled != m_enabled || echo != m_echo)
        ClearMirrors();

    m_enabled = enabled;
    m_echo = echo;
}

void WorldNpcSystem::Update(std::chrono::steady_clock::time_point aNow) noexcept
{
    if (aNow - m_lastSwitchRead >= std::chrono::seconds(3))
    {
        m_lastSwitchRead = aNow;
        const bool wasEnabled = m_enabled;
        ReadSwitches();
        if (wasEnabled != m_enabled)
            m_lastHostBroadcast = {};
    }

    ChooseHost();

    if (aNow - m_lastHostBroadcast >= kHostBroadcastInterval)
    {
        m_lastHostBroadcast = aNow;
        BroadcastHost();
    }

    auto* pLevel = m_pWorld->get_mut<Level>();
    for (auto it = m_mirrors.begin(); it != m_mirrors.end();)
    {
        if (aNow - it->second.LastSeen < kMirrorTimeout)
        {
            ++it;
            continue;
        }

        if (pLevel && it->second.Entity.is_alive())
            pLevel->Remove(it->second.Entity);
        it = m_mirrors.erase(it);
    }
}

void WorldNpcSystem::ChooseHost() noexcept
{
    if (m_host && m_host.is_alive() && m_host.has<PlayerComponent>())
    {
        const auto* pHost = m_host.get<PlayerComponent>();
        if (pHost->Puppet && pHost->Puppet.is_alive())
            return;
    }

    // The first player standing in the world.
    flecs::entity next;
    m_pWorld->each(
        [&next](flecs::entity aPlayer, const PlayerComponent& aPlayerComponent)
        {
            if (!next && aPlayerComponent.Puppet && aPlayerComponent.Puppet.is_alive())
                next = aPlayer;
        });

    if (next == m_host)
        return;

    // A new host simulates a different city: everything the old one reported goes.
    ClearMirrors();
    m_host = next;
    m_lastHostBroadcast = {};

    if (m_host)
        spdlog::info("[WorldNpc] world host is now {}", m_host.get<PlayerComponent>()->Username);
}

void WorldNpcSystem::BroadcastHost() noexcept
{
    // Switched off, nobody is host - so nobody spends the bandwidth reporting.
    const auto host = m_enabled ? m_host : flecs::entity{};
    m_pWorld->each(
        [host](flecs::entity aPlayer, const PlayerComponent& aPlayerComponent)
        {
            server::NotifyWorldHost message;
            message.set_is_host(host && aPlayer == host);
            GServer->Send(aPlayerComponent.Connection, message);
        });
}

void WorldNpcSystem::ClearMirrors() noexcept
{
    auto* pLevel = m_pWorld->get_mut<Level>();
    for (auto& [id, mirror] : m_mirrors)
    {
        if (pLevel && mirror.Entity.is_alive())
            pLevel->Remove(mirror.Entity);
    }
    m_mirrors.clear();
}

void WorldNpcSystem::HandleWorldNpcReport(PacketEvent<client::WorldNpcReport>& aMessage) noexcept
{
    auto* pPlayerManager = m_pWorld->get_mut<PlayerManager>();
    const auto sender = pPlayerManager->GetByConnectionId(aMessage.ConnectionId);

    // Only the host speaks for the city, and only while the sync is switched on.
    if (!m_enabled || !sender || sender != m_host)
        return;

    auto* pLevel = m_pWorld->get_mut<Level>();
    if (!pLevel)
        return;

    const auto now = std::chrono::steady_clock::now();

    for (const auto& npc : aMessage.get_npcs())
    {
        glm::vec3 position{npc.get_position().get_x(), npc.get_position().get_y(), npc.get_position().get_z()};
        if (!std::isfinite(position.x) || !std::isfinite(position.y) || !std::isfinite(position.z))
            continue;

        // Echoed to the host, the copy would stand inside the original - two metres aside
        // so one person can tell them apart and shoot the copy on purpose.
        if (m_echo)
            position.x += 2.f;

        auto found = m_mirrors.find(npc.get_local_id());
        if (found == m_mirrors.end())
        {
            if (m_mirrors.size() >= kMaxMirrors || npc.get_record() == 0)
                continue;

            auto entity = m_pWorld->entity()
                              .set<MovementComponent>({position, {0.f, 0.f, npc.get_rotation()}, npc.get_speed()})
                              .set<AppearanceComponent>({})
                              .set<NpcComponent>({"", "", true})
                              .set<WorldNpcComponent>({m_host, npc.get_local_id(), npc.get_record()})
                              .set<HealthComponent>({});

            // Parented to the host so the host is never sent a copy of an NPC it already
            // has - unless echo is on, for one person to see both.
            if (!m_echo)
                entity.child_of(m_host);

            pLevel->Add(entity);

            found = m_mirrors.emplace(npc.get_local_id(), Mirror{entity, now, 0}).first;
            spdlog::info("[WorldNpc] mirroring host NPC {:x} (record {:x}) as {:x}", npc.get_local_id(),
                         npc.get_record(), entity.id());
        }

        auto& mirror = found->second;
        mirror.LastSeen = now;

        if (!mirror.Entity.is_alive())
            continue;

        if (const auto* pMovement = mirror.Entity.get<MovementComponent>())
        {
            auto movement = *pMovement;
            movement.Position = position;
            movement.Rotation = {0.f, 0.f, npc.get_rotation()};
            movement.Velocity = npc.get_speed();
            movement.Tick = aMessage.get_tick();
            ++movement.Sequence;
            mirror.Entity.set<MovementComponent>(movement);
        }

        // Dead on the host, dead for everyone: the same downed/dead drawing players get.
        if (npc.get_life_state() != mirror.LifeState)
        {
            mirror.LifeState = npc.get_life_state();
            if (auto* pHealth = mirror.Entity.get_mut<HealthComponent>())
            {
                pHealth->LifeState = mirror.LifeState;
                pHealth->Health = mirror.LifeState == 0 ? pHealth->MaxHealth : 0.f;
                pLevel->BroadcastCombatState(mirror.Entity);
            }
        }
    }
}
