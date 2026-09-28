#ifndef RAVEN_GAMEDATA_H
#define RAVEN_GAMEDATA_H

#include <cstdint>
#include "Updater.h"

// Names + offsets from IL2CPP recon dump of Combat Master.
// Battle gameplay classes live in _CombatMaster.Battle.dll

namespace GameData {

    static const char* kNsPlayer     = "CombatMaster.Battle.Gameplay.Player";
    static const char* kNsCameraCtrl = "CombatMaster.Battle.Gameplay.Player.CameraController";

    static const char* kPlayerRootClass   = "PlayerRoot";
    static const char* kPlayerHealthClass = "PlayerHealth";
    static const char* kPlayerMoveClass   = "PlayerMovement";
    static const char* kPlayerMobClass    = "PlayerMobView";
    static const char* kCameraCtrlClass   = "CameraController";

    static const char* kFldMyPlayer   = "MyPlayer";
    static const char* kFldAllPlayers = "AllPlayers";

    namespace PlayerRoot {
        // -----------------------------------------------------------------
        // CameraController = 0x48 is the only field offset here with
        // direct log support: esp-cam lines show camCtrl and renderCam
        // resolving to non-null pointers on every capture, and the
        // resolved camera produces valid W2S output. Treat 0x48 as
        // verified.
        //
        // PlayerMovement (0xB0) and PlayerHealth (0xB8) are used only
        // as candidate reads. The movdump output in session 1 and
        // session 2 shows the same struct layout, so 0xB0 is
        // consistent across captures, but the two captures differ in
        // what 0x48 contains (garbage in session 1, 0.000 in session
        // 2) — which suggests at least one field boundary in this
        // struct is not what recon reported.
        //
        // The flag offsets below (0x108..0x132) are UNVERIFIED. The
        // live-filter in ESP.mm and Aimbot.mm relies on IsRealPlayer
        // at 0x132. If the filter drops every target or drops no
        // targets, the slot[N] log will show which byte is which; the
        // movdump flags line dumps 0x100..0x132 every 100 ms and can
        // be correlated against known alive/dead transitions.
        // -----------------------------------------------------------------
        constexpr uint32_t CameraController = 0x48;
        constexpr uint32_t BodyHitbox       = 0x50;
        constexpr uint32_t HeadHitbox       = 0x58;
        constexpr uint32_t PlayerMovement   = 0xB0;
        constexpr uint32_t PlayerHealth     = 0xB8;

        // UNVERIFIED — see note above.
        constexpr uint32_t IsOwner          = 0x108;
        constexpr uint32_t HasControl       = 0x109;
        constexpr uint32_t IsVisible        = 0x10A;
        constexpr uint32_t IsRealPlayer     = 0x132;
    }

    namespace PlayerMovement {
        // -----------------------------------------------------------------
        // DEAD OFFSETS — do not write.
        //
        // The 2026-09-24 18:33:39 build wrote pitch to +0x60 and yaw to
        // +0x68 on every tick. Both offsets were wrong. Scribbling
        // arbitrary floats into live IL2CPP struct memory caused Unity to
        // follow a corrupted byte as a pointer and crash inside
        // UnityRepaint with EXC_BAD_ACCESS (KERN_INVALID_ADDRESS).
        //
        // 0x60, 0x68, and 0x78 read 0.000 across every available capture.
        // They are not rotation.
        // -----------------------------------------------------------------
        constexpr uint32_t DEAD_0x60 = 0x60;
        constexpr uint32_t DEAD_0x68 = 0x68;
        constexpr uint32_t DEAD_0x78 = 0x78;

        // -----------------------------------------------------------------
        // CANDIDATE OFFSETS — unverified. Do not write.
        //
        // 0x70 and 0x74 are the two offsets whose float reads in the
        // session-1 capture most resemble a pitch/yaw pair: 0x70 reads
        // -90.000 at exactly the tick the aim-dbg wantPitch sat near
        // -4.4, and 0x74 walks through [202, 344] which is inside a
        // yaw-in-degrees envelope if the game stores yaw unwrapped.
        //
        // The session-2 capture tells a different story. In that
        // capture 0x60 == 0x70 at every sample, 0x50/0x54/0x58 hold a
        // unit-length forward vector, 0x60 holds (0, 1, 0, 0) — an up
        // vector — and 0x74 does NOT track the aim-dbg wantYaw that
        // accompanies it. That is not a stable field layout; it looks
        // like two different code paths resolving the same struct
        // pointer against two different object layouts.
        //
        // Neither capture contains a moving local player during the
        // movdump window: the frozen-src detector fired at 00:27:36
        // and src stayed byte-identical for the remainder of that life.
        // There is therefore no correlation between 0x70/0x74 and a
        // known camera pan on disk.
        //
        // Do not promote these to confirmed. Do not write to them.
        // -----------------------------------------------------------------
        constexpr uint32_t CANDIDATE_VerticalRotation  = 0x70;
        constexpr uint32_t CANDIDATE_HorRotationAngles = 0x74;
    }

    static const char* kMGetHealth        = "get_Health";
    static const char* kMGetMaxHealth     = "get_MaxHealth";
    static const char* kMGetArmor         = "get_Armor";
    static const char* kMGetIsDead        = "get_IsDead";
    static const char* kMGetIsDowned      = "get_IsDowned";

    static const char* kMGetTeamId        = "get_TeamId";
    static const char* kMGetNetworkId     = "get_NetworkId";
    static const char* kMGetActiveMobView = "get_ActiveMobView";
    static const char* kMGetIsVisible     = "get_IsVisible";
    static const char* kMGetMainCamera    = "get_MainCamera";
    static const char* kMGetTransform     = "get_transform";

    static const char* kMGetHeadTransform  = "get_HeadTransform";
    static const char* kMGetNeckTransform  = "get_NeckTransform";
    static const char* kMGetChestTransform = "get_ChestTransform";
    static const char* kMGetSpineTransform = "get_SpineTransform";
    static const char* kMGetPelvisTransform = "get_PelvisTransform";

    static const char* kMGetRenderCamera  = "get_RenderCamera";
    static const char* kMGetPosition      = "get_position";
    static const char* kMWorldToScreen    = "WorldToScreenPoint";

    namespace List {
        constexpr uint32_t Items = 0x10;
        constexpr uint32_t Size  = 0x18;
    }

    namespace Array {
        constexpr uint32_t Data = 0x20;
    }

    namespace Bone {
        constexpr int Head   = 11;
        constexpr int Neck   = 12;
        constexpr int Chest  = 20;
        constexpr int Pelvis = 1;
    }
}

#endif
