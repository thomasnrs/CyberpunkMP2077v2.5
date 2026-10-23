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

    // Hand-decoded by CyberpunkMP against an older patch where the base ended at 0xB90. The 2.5
    // reflection data puts the base end at 0xBA0 and the size at 0xBF0, so these are shifted by
    // 0x10. Unverified on 2.5 - check in game before trusting them.
    void * interactionsMaybe;           // BA0
    Transmission * transmissionData;    // BA8
    Engine * engineData;                // BB0
    void * burnoutData;                 // BB8

    uint8_t unkBC0[0xBF0 - 0xBC0]; // BC0
};
RED4EXT_ASSERT_SIZE(WheeledBaseObject, 0xBF0);
} // namespace vehicle
using vehicleWheeledBaseObject = vehicle::WheeledBaseObject;
using WheeledObject = vehicle::WheeledBaseObject;
} // namespace RED4ext

// clang-format on
