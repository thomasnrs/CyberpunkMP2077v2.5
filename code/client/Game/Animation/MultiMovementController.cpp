#include "MultiMovementController.h"

#include "AnimationData.h"
#include "Game/Utils.h"

#include <RED4ext/Scripting/Natives/moveComponent.hpp>
#include <RED4ext/Scripting/Natives/Generated/anim/AnimFeature_NPCExploration.hpp>

#include "States/Spawning.h"

namespace
{
// Which controller slots the engine actually calls, logged once each. The vtable below is an
// engine ABI copied by index from the idle controller; if a patch moves those slots, the
// remote puppet stands still without any error, and this is the only way to see it.
void TraceSlot(uint32_t aSlot, const char* apName)
{
    static std::atomic<uint64_t> s_seen{0};
    const uint64_t bit = 1ull << (aSlot / 8);
    if ((s_seen.fetch_or(bit) & bit) == 0)
        spdlog::info("[MultiMovement] engine called slot 0x{:X} ({}) for the first time", aSlot, apName);
}
}
Core::RawFunc<316482401, void (*)(Red::AnimationControllerComponent* AnimationController, Red::CName Name, Red::Handle<Red::anim::AnimFeature> Feature)> ApplyFeature;

RED4ext::Memory::PoolAI_Movement* MultiMovementController::GetMemoryPool()
{
    return RED4ext::Memory::PoolAI_Movement::Get();
}

MultiMovementController::~MultiMovementController() = default;

void MultiMovementController::PreTick(float delta)
{
    TraceSlot(0x10, "PreTick");
}

void MultiMovementController::Tick(float delta)
{
    TraceSlot(0x18, "Tick");
    if (!m_pState)
        return;

    States::Base::Update update;
    update.Delta = delta;
    update.Speed = States::Base::BandSpeed(m_speed, m_locomotion);

    while (auto transition = m_pState->Process(update))
    {
        m_pState = std::move(transition->State);  // NOLINT(bugprone-unchecked-optional-access)
    }
}

void MultiMovementController::GetDeltaTransform(Red::Vector4& positionDelta, Red::Quaternion& rotationDelta)
{
    TraceSlot(0x20, "GetDeltaTransform");
    // Runs every animation frame on the ANIMATION thread, and mounting a puppet into a
    // vehicle REPARENTS its entity - the placement chain below can go away mid-seat.
    // These were unchecked dereferences until a driver's game died ~25s after a remote
    // puppet mounted into their moving car; a zero delta is always a safe answer.
    if (!m_pComponent || !m_pComponent->owner || !m_pComponent->owner->placedComponent)
    {
        if (!m_nullPlacementLogged)
        {
            m_nullPlacementLogged = true;
            spdlog::warn("[MultiMovement] GetDeltaTransform with missing placement chain - entity reparented under us (mounted?)");
        }

        positionDelta = {0.f, 0.f, 0.f, 0.f};
        rotationDelta = {0.f, 0.f, 0.f, 1.f};
        return;
    }

    const auto& rawPosition = m_pComponent->owner->placedComponent->localTransform.Position;
    const auto& rawRotation = m_pComponent->owner->placedComponent->localTransform.Orientation;
    const glm::vec3 pos = Game::ToGlm(rawPosition);
    const auto rot = Game::ToGlm(rawRotation);

    auto angles = eulerAngles(rot);
    angles.z = m_angle - angles.z;

    const Red::Vector4 position{pos.x, pos.y, pos.z, 0.f};

    positionDelta = {m_position.X - position.X, m_position.Y - position.Y, m_position.Z - position.Z, 0.f};
    rotationDelta = Game::ToRed(glm::quat(angles));

    // Target, current and the delta handed back, every five seconds per controller. If the
    // target never changes, interpolation is not feeding SetTransform; if it changes and the
    // delta is right but the puppet stays put, the engine is ignoring the delta.
    {
        static std::mutex s_lock;
        static std::unordered_map<const void*, std::chrono::steady_clock::time_point> s_last;
        std::lock_guard lock(s_lock);
        auto& last = s_last[this];
        const auto now = std::chrono::steady_clock::now();
        if (now - last >= std::chrono::seconds(5))
        {
            last = now;
            spdlog::info("[MultiMovement] target ({:.1f}, {:.1f}, {:.1f}) current ({:.1f}, {:.1f}, {:.1f}) delta {:.2f}m speed {:.1f}",
                         m_position.X, m_position.Y, m_position.Z, pos.x, pos.y, pos.z,
                         std::sqrt(positionDelta.X * positionDelta.X + positionDelta.Y * positionDelta.Y +
                                   positionDelta.Z * positionDelta.Z),
                         m_speed);
        }
    }

    // Interpolation stops feeding SetTransform while a puppet is seated (AttachedComponent
    // gates it), so m_position freezes at the mount spot. If the engine still asks this
    // controller for deltas while the car drives away, the answer grows without bound -
    // exactly the kind of impulse that hurls entities. Log the first sighting; the
    // timestamp against the mount line names the guilty tick.
    const float dx = positionDelta.X, dy = positionDelta.Y, dz = positionDelta.Z;
    if (dx * dx + dy * dy + dz * dz > 100.f * 100.f && !m_runawayLogged)
    {
        m_runawayLogged = true;
        spdlog::warn("[MultiMovement] delta runaway ({:.0f}m) - frozen target queried while the entity moves (seated in a driving car?)",
                     std::sqrt(dx * dx + dy * dy + dz * dz));
    }
}

void MultiMovementController::sub_28(bool& unk)
{
    TraceSlot(0x28, "sub_28");
    unk = false;
}

void MultiMovementController::sub_30(Red::Vector4& positionDelta, Red::Quaternion& rotationDelta)
{
    TraceSlot(0x30, "sub_30");
    
}

void MultiMovementController::sub_38(Red::Vector4& position, Red::Quaternion& rotation, bool& unk1, bool& unk2)
{
    TraceSlot(0x38, "sub_38");
    
}

void MultiMovementController::SendAnimationParameters(float delta, Red::Vector4& position, Red::Quaternion& orientation)
{
    TraceSlot(0x40, "SendAnimationParameters");
    if (!m_pState)
        return;

    AnimationData data;
    data.controller = GetName();

    GetAnimationParameters(data);

    m_animationDriver.SendParameters(data);
}

void MultiMovementController::sub_48(RED4ext::Vector4& somePosition1, RED4ext::Quaternion& someRotation1, RED4ext::Vector4& somePosition2, RED4ext::Quaternion& someRotation2)
{
    
}

void MultiMovementController::sub_50(RED4ext::Vector4& somePosition1, RED4ext::Quaternion& someRotation1, float unk, RED4ext::Vector4& somePosition2, RED4ext::Quaternion& someRotation2)
{
    
}

Red::CName MultiMovementController::GetName() const
{
    return NAME;
}

bool MultiMovementController::sub_60()
{
    TraceSlot(0x60, "sub_60");
    return true;
}

void MultiMovementController::sub_68()
{
    TraceSlot(0x68, "sub_68");
    
}

void MultiMovementController::sub_70()
{
    TraceSlot(0x70, "sub_70");
    
}

void MultiMovementController::Mount(RED4ext::move::Component& movable, Red::Handle<Red::ent::Entity> owner)
{
    TraceSlot(0x78, "Mount");
    
}

void MultiMovementController::Attach(Red::move::Component& movable)
{
    TraceSlot(0x80, "Attach");
    if (!movable.owner || !movable.owner->placedComponent)
    {
        spdlog::warn("[MultiMovement] Attach skipped with missing placement chain");
        return;
    }

    m_pComponent = &movable;

    const auto& pos = movable.owner->placedComponent->localTransform.Position;
    const auto& rot = movable.owner->placedComponent->localTransform.Orientation;

    const auto quat = Game::ToGlm(rot);
    SetTransform(Red::Vector4{pos.x, pos.y, pos.z, 0.f}, eulerAngles(quat).z, 0.f);

    m_animationDriver.Attach(movable.owner);

    m_pState = MakeUnique<States::Spawning>(m_host);
    m_pState->Enter();
}

void MultiMovementController::Detach(Red::move::Component& movable)
{
    TraceSlot(0x88, "Detach");
    m_animationDriver.Detach();

    m_pState.reset();

    m_pComponent = nullptr;
}

void MultiMovementController::GetAnimationParameters(AnimationData& animationData)
{
    TraceSlot(0x90, "GetAnimationParameters");
    if (!m_pState)
        return;

    m_pState->GetAnimationData(animationData);
}

void MultiMovementController::SetTransform(const Red::Vector4& aPosition, float aAngle, float speed, uint32_t aLocomotion)
{
    m_position = aPosition;
    m_angle = aAngle;
    m_speed = speed;
    m_locomotion = aLocomotion;
}

float MultiMovementController::GetAnimLength(Red::CName aName) const
{
    return m_animationDriver.GetAnimLength(aName);
}

float MultiMovementController::Host::GetAnimLength(Red::CName aName) const
{
    return Parent->GetAnimLength(aName);
}

float MultiMovementController::Host::GetCurrentSpeed() const
{
    return Parent->m_speed;
}

void MultiMovementController::Reset()
{
    m_pComponent->representation.stack.Clear();
    m_pComponent->representation.activeIndex = -1;
    m_pComponent->representation.activeEntry = nullptr;
    m_pComponent->representation.active = false;
}
