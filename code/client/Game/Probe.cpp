#include "Probe.h"

#include "Game/CharacterCustomizationSystem.h"
#include "Game/Utils.h"

namespace
{
bool IsReadable(const void* apAddress, size_t aSize)
{
    if (!apAddress)
        return false;

    MEMORY_BASIC_INFORMATION info{};
    if (!VirtualQuery(apAddress, &info, sizeof(info)) || info.State != MEM_COMMIT)
        return false;

    constexpr DWORD readable = PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY | PAGE_EXECUTE_READ |
                               PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;
    if ((info.Protect & readable) == 0 || (info.Protect & PAGE_GUARD) != 0)
        return false;

    const auto end = reinterpret_cast<uintptr_t>(apAddress) + aSize;
    return end <= reinterpret_cast<uintptr_t>(info.BaseAddress) + info.RegionSize;
}

template<typename T>
T ReadAt(const void* apBase, uintptr_t aOffset)
{
    return *reinterpret_cast<const T*>(reinterpret_cast<uintptr_t>(apBase) + aOffset);
}

// What a DynArray looks like in memory; its fields are private in the SDK.
struct RawArray
{
    void* data;
    uint32_t capacity;
    uint32_t size;
};

bool LooksLikeArray(const void* apBase, uintptr_t aOffset)
{
    const auto array = ReadAt<RawArray>(apBase, aOffset);
    if (array.size > array.capacity || array.capacity > 4096)
        return false;
    return array.capacity == 0 || IsReadable(array.data, 1);
}
}

Red::vehicle::RigidBody* Game::Probe::VehicleRigidBody(Red::vehicle::BaseObject* apVehicle)
{
    // Most likely first: the +8 before isReversing applies, the +8 before archetype may not.
    static constexpr uintptr_t kCandidates[] = {0x2D8, 0x2E0, 0x2D0};
    static std::optional<uintptr_t> s_offset;
    static bool s_failed = false;

    if (!apVehicle || s_failed)
        return nullptr;

    if (s_offset)
        return ReadAt<Red::vehicle::RigidBody*>(apVehicle, *s_offset);

    if (!apVehicle->placedComponent)
        return nullptr;

    const auto entityPosition = Game::ToGlm(apVehicle->placedComponent->worldTransform.Position);

    for (const auto offset : kCandidates)
    {
        auto* pBody = ReadAt<Red::vehicle::RigidBody*>(apVehicle, offset);
        if (!IsReadable(pBody, sizeof(Red::vehicle::RigidBody)))
        {
            spdlog::info("[Probe] vehicle rigidBody @0x{:X}: not a readable pointer", offset);
            continue;
        }

        const auto& q = pBody->orientation;
        const float norm = std::sqrt(q.i * q.i + q.j * q.j + q.k * q.k + q.r * q.r);
        const auto bodyPosition = Game::ToGlm(pBody->currentTransform.Position);
        const float distance = glm::distance(bodyPosition, entityPosition);

        spdlog::info("[Probe] vehicle rigidBody @0x{:X}: |orientation| = {:.3f}, {:.2f} m from the entity", offset,
                     norm, distance);

        if (std::abs(norm - 1.f) < 0.02f && distance < 5.f)
        {
            s_offset = offset;
            spdlog::info("[Probe] vehicle rigidBody resolved at 0x{:X}", offset);
            return pBody;
        }
    }

    s_failed = true;
    spdlog::error("[Probe] vehicle rigidBody matched no candidate - vehicle position sync is disabled");
    return nullptr;
}

Red::Handle<Red::game::ui::CharacterCustomizationState>* Game::Probe::CustomizationStateHandle(
    Red::game::ui::CharacterCustomizationSystem* apSystem)
{
    using StateHandle = Red::Handle<Red::game::ui::CharacterCustomizationState>;

    static StateHandle s_empty;
    static std::optional<uintptr_t> s_offset;
    static bool s_reportedMiss = false;

    if (!apSystem)
        return &s_empty;

    if (s_offset)
        return reinterpret_cast<StateHandle*>(reinterpret_cast<uintptr_t>(apSystem) + *s_offset);

    static const void* s_stateVtable = []
    {
        StateHandle fresh;
        CreateHandle_CharacterCustomizationState(&fresh);
        return fresh.instance ? *reinterpret_cast<void* const*>(fresh.instance) : nullptr;
    }();

    if (!s_stateVtable)
        return &s_empty;

    // 0x78 on 2.31, and the class grew by 0x40 before or after it.
    for (uintptr_t offset = 0x78; offset <= 0xB8; offset += 8)
    {
        const auto* pInstance = ReadAt<const void*>(apSystem, offset);
        if (!IsReadable(pInstance, sizeof(void*)))
            continue;

        if (*reinterpret_cast<void* const*>(pInstance) == s_stateVtable)
        {
            s_offset = offset;
            spdlog::info("[Probe] CharacterCustomizationSystem state handle resolved at 0x{:X}", offset);
            return reinterpret_cast<StateHandle*>(reinterpret_cast<uintptr_t>(apSystem) + offset);
        }
    }

    // The state is legitimately empty for long stretches of play, so a miss is not final.
    if (!s_reportedMiss)
    {
        s_reportedMiss = true;
        spdlog::info("[Probe] CharacterCustomizationSystem state handle not found yet (0x78-0xB8) - will retry");
    }
    return &s_empty;
}

bool Game::Probe::VirtualSlotVerified(const void* apObject, uintptr_t aSlotOffset, const char* apWhat)
{
    // Slot targets disassembled and confirmed on this build, as {slot, RVA}. Empty until the
    // first 2.5 session logs them.
    static constexpr std::pair<uintptr_t, uintptr_t> kConfirmed[] = {{0, 0}};

    const auto* pVtable = apObject ? *reinterpret_cast<const uintptr_t* const*>(apObject) : nullptr;
    if (!IsReadable(pVtable, aSlotOffset + sizeof(uintptr_t)))
    {
        spdlog::error("[Probe] {}: no readable vtable", apWhat);
        return false;
    }

    const auto target = pVtable[aSlotOffset / sizeof(uintptr_t)];
    const auto rva = target - reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));

    for (const auto& [slot, confirmed] : kConfirmed)
    {
        if (slot == aSlotOffset && confirmed == rva)
        {
            spdlog::info("[Probe] {}: vtable+0x{:X} -> Cyberpunk2077.exe+0x{:X}, confirmed", apWhat, aSlotOffset, rva);
            return true;
        }
    }

    spdlog::warn("[Probe] {}: vtable+0x{:X} -> Cyberpunk2077.exe+0x{:X}, not confirmed on this build - not calling it",
                 apWhat, aSlotOffset, rva);
    return false;
}

bool Game::Probe::MoveComponentLayoutOk(Red::move::Component* apComponent)
{
    static std::optional<bool> s_result;
    if (s_result)
        return *s_result;

    if (!apComponent)
        return false;

    const auto* pParent = apComponent->representation.parent;
    s_result = pParent == apComponent;

    if (*s_result)
        spdlog::info("[Probe] moveComponent representation @0x138: parent points back - layout holds");
    else
        spdlog::error("[Probe] moveComponent representation @0x138: parent is {} not {} - remote animation is "
                      "disabled",
                      static_cast<const void*>(pParent), static_cast<const void*>(apComponent));

    return *s_result;
}

void Game::Probe::CheckCustomizationState(const Red::game::ui::CharacterCustomizationState* apState,
                                          const char* apWhere)
{
    static bool s_logged = false;
    if (s_logged || !apState)
        return;
    s_logged = true;

    // head, body, arms, perspectiveInfo, tags
    static constexpr uintptr_t kArrays[] = {0x70, 0x80, 0x90, 0xA0, 0xB0};

    auto check = [apState](uintptr_t aShift)
    {
        uint32_t valid = 0;
        for (const auto offset : kArrays)
            valid += LooksLikeArray(apState, offset + aShift) ? 1 : 0;
        const auto gender = ReadAt<uint8_t>(apState, 0x44 + aShift);
        return std::pair{valid, gender};
    };

    const auto [valid, gender] = check(0);
    spdlog::info("[Probe] CharacterCustomizationState ({}): {}/5 arrays look valid at 2.31 offsets, "
                 "isBodyGenderMale@0x44 = {}",
                 apWhere, valid, gender);

    if (valid != 5 || gender > 1)
    {
        const auto [shiftedValid, shiftedGender] = check(0x20);
        spdlog::error("[Probe] CharacterCustomizationState layout looks moved; with +0x20: {}/5 arrays, "
                      "gender byte = {}",
                      shiftedValid, shiftedGender);
    }
}
