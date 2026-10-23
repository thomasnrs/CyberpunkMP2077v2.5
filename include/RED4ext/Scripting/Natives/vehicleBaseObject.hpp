#pragma once

#include <RED4ext/Common.hpp>
#include <RED4ext/NativeTypes.hpp>
#include <RED4ext/Scripting/Natives/Generated/game/Object.hpp>
#include <RED4ext/Scripting/Natives/Generated/Vector3.hpp>
#include <RED4ext/Scripting/Natives/Generated/Quaternion.hpp>
#include <RED4ext/Scripting/Natives/Generated/Matrix.hpp>
#include <RED4ext/Scripting/Natives/Generated/WorldTransform.hpp>
#include <RED4ext/Scripting/Natives/Generated/Box.hpp>
#include <cstdint>

namespace RED4ext
{
namespace AI
{
struct Archetype;
}

namespace vehicle
{

struct BaseObject;


#pragma pack(push, 1)
struct SuspensionBase {
    // virtual ~SuspensionBase();              // 00
    // virtual uint64_t OnAttach(BaseObject*); // 08
    // virtual uint64_t OnDetach();            // 10
    // virtual uint64_t OnTeleport(
    //     TeleportEvent*);                  // 18 reponds to vehicleTeleportEvent
    // virtual uint64_t PostReloadTweakDB(); // 20 sets mass & inertia tensor
    // virtual uint64_t UpdateTransform();   // 28
    // virtual void sub_30(uint32_t*, float*); // 30
    // virtual void sub_38(
    //     float deltaTime); // 38 checks for vehicle being Z < -100, teleports if
    //                       // so (VehicleTeleportationIfFallsUnderWorld @ RVA
    //                       // 0x4781A38)
    // virtual void FixedUpdate_PostSolve(float deltaTime);              // 40
    // virtual uint64_t BuildJobs_FixedUpdate_PreSolve(uint64_t, float); // 48
    // virtual void FixedUpdate_PreSolve(
    //     float deltaTime); // 50 also called w/o arg? sets this->velocity from
    //                       // physicsData->velocity, applies water resistance
    // virtual uint64_t FixedUpdate_PostSolve2(float deltaTime); // 58
    // virtual void UpdateStuck(){};                             // 60
    // virtual uint64_t InterpolateMovement(float);              // 68
    // virtual uint64_t sub_70(int, char);                       // 70
    // virtual uint64_t sub_78();                                // 78
    // virtual void sub_80(){};                                  // 80
    // virtual void sub_88(){};                                  // 88
    // virtual void SetUnk70To1();                               // 90
    // virtual void sub_98(bool){};                              // 98
    // virtual uint64_t sub_A0(uint64_t){};                      // A0
    // virtual uint64_t IntializeVectorQuaternion(uint64_t);     // A8
    // virtual uint64_t sub_B0(int, float);                      // B0
    // virtual bool UpdateSuspensionStuff();                     // B8
    // virtual bool IsInAir();                                   // C0
    // virtual bool IsFlippedOver();                             // C8
    // virtual bool sub_D0() { return false; }                   // D0
    // virtual void sub_D8(char);                                // D8
    // virtual double GetSteeringWheelTurnDeg();                 // E0
    // virtual float GetMaxWheelTurnDeg();                       // E8
    // virtual void sub_F0(){};                                  // F0
    // virtual void ForceAISpecificSettings(){};                 // F8
    // virtual void sub_100(uint32_t*, float*){};                // 100
    // virtual void sub_108(){};                                 // 108
    // virtual void sub_110(){};                                 // 110
    // virtual void sub_118(void*, RED4ext::Transform*){};       // 118
    // virtual uint64_t PostAutopilotUpdate(); // 120 updates some animation stuff
    // virtual uint64_t UpdateBlackboard();    // 128 update blackboard, effectdata
    // virtual void sub_130();                 // 130
    // virtual uint64_t sub_138();             // 138
    // virtual void ApplyDrivingModelData(
    //     THandle<game::data::VehicleDriveModelData_Record>*); // 140 populates
    //                                                         // some variables
    //                                                         // along with most
    //                                                         // of insert1

    uint64_t unk08;
    Vector3 velocity;                                       // 10
    uint32_t unk1C;
    uint8_t unk20;                  // 20 checked in fixed update
    uint8_t unk21[7];
    WorldTransform worldTransform;  // 30
    uint32_t unk48;
    uint8_t unk50; // is underworld?
    uint8_t unk51[7];
    uint64_t unk58;
    BaseObject* parent;             // 60
    class WaterControl* waterControl;
    uint8_t unk70;
    uint8_t unk71[7];
    uint64_t unk78;
    // last transform? used in forceMoveTo to determine speed
    WorldTransform worldTransform2; // 80
    // Set to 1.0 when awake, counts down when sleep conditions are met - when
    // 0.0, vehicle enters sleep state, and is set to -1.0
    float sleepTimer; // A0
    float unkA4;      // A4
    // counts from 0.5 down to 0.0
    float unkA8;        // A8
    float setTo0point5; // AC
    /*
    B0 in 2.0
    HIWORD(this) compared to physicsProxyManager->unk102010[this]
    0x00011a70 on ground,
    0x00011a84 in air,
    0xffffffff in water,
    0x00012d45 above water
    0x00013404 sliding
    0x00013f53 hitting ground
    0x00014aa8 upsidedown over ground
    0x00014659
    0x00014aad
    0x00014a9d
    */
    int32_t unkB0; // B0
    uint8_t unkB4;
    uint8_t unkB5;
    uint8_t unkB6;
    uint8_t unkB7;
    bool isMoving;         // B8 computed from chassis component
    uint8_t unk_2_0_new_1; // B9
    uint8_t unkBA;         // BA
    bool unkBB;            // BB is player controllered maybe
    bool flippedOver;         // BC set from vehicle->unk361
    bool hasInput;         // true if any vehicle->acceleration, et al != 0
    bool unkBE; // true if any vehicle->unk568->unk60 value != 0 - isMoving?
    uint8_t unkBF;
    uint8_t unkC0;
    uint16_t unkC1;
    uint8_t unkC3;
    float has_been_flipped_over_for_some_time_delay; // C4
    float unkC8;                                     // C8
    uint32_t unkCC;                                  // CC
    void* physicsBaseStruct2;                       // D0
    void* unkD8;                                     // D8
};
#pragma pack(pop)

struct RigidBody
{
    Vector3 force;              // 00
    Vector3 torque;             // 0C
    Vector3 velocity;           // 18
    Vector3 angularVelocity;    // 24
    Quaternion orientation;     // 30
    float inverseMass;
    uint32_t unk48[3];
    Matrix localInertiaTensor;
    Matrix worldInertiaTensor;
    Matrix invertedLocalInertiaTensor;
    Matrix invertedWorldInertiaTensor;
    WorldTransform currentTransform;
    Vector4 worldPosition;
    BaseObject* vehicle;
    uint64_t unk188;
    Box bounds;
    // gravity enabled, related to PxActorFlag
    uint8_t unk1B0;
    uint8_t unk1B1;
    uint8_t unk1B2;
    uint8_t unk1B3;
    // set to 100000.0 in a function
    float alternativeChassisMass; // 1B4
    uint8_t usesAlternativeChassisMass;
    uint8_t unk1B9;
    uint8_t unk1BA;
    uint8_t unk1BB;
    float total_mass;
    float chassis_mass; // 1C0
    uint8_t usesInertiaTensor;
    uint8_t unk1C5;
    uint8_t unk1C6;
    uint8_t unk1C7;
    Vector3 momentOfInertiaScale;
    Vector3 centerOfMass;
};

struct RuntimeData {
  Vector4 unk00;
  WorldTransform transform;
  Vector4 linearVelocity;
  Vector4 linearAcceleration;
  float unk50[30];
  float driveSpeedSigned;

};

struct BaseObject : game::Object
{
    static constexpr const char* NAME = "vehicleBaseObject";
    static constexpr const char* ALIAS = "VehicleObject";

    uint8_t unk240[0x25C - 0x240]; // 240
    bool isOnGround;               // 25C
    uint8_t unk25D[0x260 - 0x25D]; // 25D
    uint32_t physicsState;         // 260
    float acceleration;            // 264
    float deceleration;            // 268
    float handbrake;               // 26C
    float strafeY;                 // 270
    float strafeX;                 // 274
    float turnInput;               // 278
    float leanFB;                  // 27C
    float rockFB;                  // 280
    uint8_t unk26C[0x2A3 - 0x284]; // 284
    bool isReversing;              // 2A3
    uint8_t unk2A4[0x2BC - 0x2A4]; // 2A4
    float burnout;                 // 2BC
    uint8_t unk2C0[0x2C8 - 0x2C0]; // 2C0
    SuspensionBase * suspension;   // 2C8
    RigidBody * rigidBody;         // 2D0

    Handle<ISerializable> curveSetData;  // 2D8
    Handle<ISerializable> chassis;   // 2E8
    float unk2F8[16]; // 2F8
    uint64_t chassisType; // 338
    WorldTransform worldTransform; // 340

    uint8_t unk360[0x3A0 - 0x360]; // 360
    Ref<AI::Archetype> archetype;  // 3A0

    uint8_t unk3B8[0x5D0 - 0x3B8]; // 3B8
    RuntimeData *runtimeData;      // 5D0
    uint8_t unk5D8[0x6D2 - 0x5D8]; // 5D8

    bool isVehicleOnStateLocked;   // 6D2
    uint8_t unk6D3[0xBA0 - 0x6D3]; // 6D3
};
RED4EXT_ASSERT_SIZE(BaseObject, 0xBA0);
RED4EXT_ASSERT_OFFSET(BaseObject, isOnGround, 0x25C);
RED4EXT_ASSERT_OFFSET(BaseObject, acceleration, 0x264);
RED4EXT_ASSERT_OFFSET(BaseObject, deceleration, 0x268);
RED4EXT_ASSERT_OFFSET(BaseObject, isReversing, 0x2A3);
RED4EXT_ASSERT_OFFSET(BaseObject, burnout, 0x2BC);
RED4EXT_ASSERT_OFFSET(BaseObject, archetype, 0x3A0);
RED4EXT_ASSERT_OFFSET(BaseObject, isVehicleOnStateLocked, 0x6D2);
} // namespace vehicle
using vehicleBaseObject = vehicle::BaseObject;
using VehicleObject = vehicle::BaseObject;
} // namespace RED4ext
