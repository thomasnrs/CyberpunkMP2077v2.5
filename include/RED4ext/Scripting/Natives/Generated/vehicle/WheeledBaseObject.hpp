#pragma once

// clang-format off

// This file is generated from the Game's Reflection data

#include <cstdint>
#include <RED4ext/Common.hpp>
#include <RED4ext/Scripting/Natives/Generated/vehicle/BaseObject.hpp>

namespace RED4ext
{
namespace vehicle
{
struct Transmission {
    uint64_t unk00;
};
struct Engine {
    uint8_t unk00[0x61]; // 00
    uint8_t unk61; // 61
};
struct __declspec(align(0x10)) WheeledBaseObject : vehicle::BaseObject
{
    static constexpr const char* NAME = "vehicleWheeledBaseObject";
    static constexpr const char* ALIAS = "WheeledObject";

    // Hand-decoded by CyberpunkMP. This block is 0x50 bytes on 2.31 and on 2.5, so the
    // fields moved with the base (0xBA0 -> 0xBC0). Verified only by that size argument.
    void * interactionsMaybe;           // BC0
    Transmission * transmissionData;    // BC8
    Engine * engineData;                // BD0
    void * burnoutData;                 // BD8

    uint8_t unkBE0[0xC10 - 0xBE0]; // BE0
};
RED4EXT_ASSERT_SIZE(WheeledBaseObject, 0xC10);
} // namespace vehicle
using vehicleWheeledBaseObject = vehicle::WheeledBaseObject;
using WheeledObject = vehicle::WheeledBaseObject;
} // namespace RED4ext

// clang-format on
