#pragma once

// clang-format off

#include <cstdint>
#include <RED4ext/Common.hpp>
#include <RED4ext/Scripting/IScriptable.hpp>
#include <RED4ext/Scripting/Natives/Generated/ent/EntityID.hpp>
#include <RED4ext/Scripting/Natives/Generated/ECustomCameraTarget.hpp>
#include <RED4ext/Scripting/Natives/Generated/RenderSceneLayerMask.hpp>
#include <RED4ext/Scripting/Natives/Generated/ent/IPlacedComponent.hpp>
#include <RED4ext/Scripting/Natives/Generated/ent/ComponentsStorage.hpp>

namespace RED4ext
{
namespace world
{
struct RuntimeScene;
}

enum class EntityStatus : uint8_t
{
    Undefined = 0,
    Initializing = 1,
    Detached = 2,
    Attaching = 3,
    Attached = 4,
    Detaching = 5,
    Uninitializing = 6,
    Uninitialized = 7,
};

namespace ent
{
struct Entity : IScriptable
{
    static constexpr const char* NAME = "entEntity";
    static constexpr const char* ALIAS = "Entity";

    uint8_t unk40[0x48 - 0x40]; // 40
    EntityID id; // 48
    uint8_t unk50[0x70 - 0x50]; // 50
    ComponentsStorage componentsStorage; // 70
    IPlacedComponent* placedComponent; // B0
    uint8_t unkB8[0x154 - 0xB8]; // B8
    ECustomCameraTarget customCameraTarget; // 154
    uint8_t unk155[0x15B - 0x155]; // 155
    RenderSceneLayerMask renderSceneLayerMask; // 15B
    uint8_t unk15C[0x160 - 0x15C]; // 15C
};
} // namespace ent
} // namespace RED4ext

// clang-format on
