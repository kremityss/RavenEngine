#ifndef RAVEN_SETTINGS_H
#define RAVEN_SETTINGS_H

namespace RavenSettings {
    void load();
    void save();

    extern bool  aimEnabled;
    extern int   aimActivation;
    extern int   aimBone;
    extern float aimFov;
    extern float aimSmooth;
    extern float aimMaxDist;
    extern bool  aimPrediction;
    extern float aimPredictionStrength;
    extern float aimPredictionVelocity;
    extern float aimAcceleration;
    extern bool  aimIgnoreTeammates;
    extern bool  aimVisCheck;
    extern float aimDelay;
    extern float aimSwitchDelay;
    extern bool  aimShowCircle;
    extern float aimCircleRadius;
    extern float aimCircleThickness;
    extern int   aimPriority;
    extern int   aimCurve;
    extern float aimStrength;
    extern bool  aimDynamicFov;
    extern bool  gyroEnabled;
    extern float gyroSmooth;
    extern float gyroFov;
    extern int   gyroCurve;
    extern float gyroStabilizer;
    extern float gyroMicroCorrection;
    extern bool  gyroLowLatency;

    extern bool  espEnabled;
    extern bool  espBox;
    extern bool  espCorner;
    extern bool  espSkeleton;
    extern bool  espSnaplines;
    extern bool  espName;
    extern bool  espDistance;
    extern bool  espHealth;
    extern bool  espTeam;
    extern bool  espVisibleOnly;
    extern int   espSnaplinePosition;
    extern bool  espHealthBar;
    extern bool  espArmorBar;
    extern bool  espPerformanceMode;
    extern bool  espAutoOptimize;
    extern bool  espFpsCounter;
    extern bool  espWeapon;
    extern int   espEnemyColor;
    extern int   espVisibleColor;
    extern int   espSkeletonColor;
    extern int   espBoxColor;
    extern int   espBoxStyle;
    extern bool  espRgb;
    extern bool  espHeadDot;
    extern float espBoxScale;

    extern bool  visCrosshair;
    extern int   visCrosshairStyle;
    extern float visCrosshairSize;
    extern float visCrosshairThickness;
    extern bool  visFovCircle;
    extern float visFovRadius;
    extern float visFovThickness;
    extern bool  visRemoveFog;
    extern bool  visNightMode;
    extern bool  visBrightnessBoost;
    extern float visBrightness;
    extern bool  visNoFlash;
    extern bool  visNoSmoke;
    extern bool  visBetterTextures;
    extern float visCameraFov;
    extern bool  visThirdPerson;

    extern bool  wpnNoRecoil;
    extern bool  wpnNoSpread;
    extern float wpnRecoilStrength;
    extern bool  wpnFastReload;
    extern bool  wpnRapidFire;
    extern float wpnFireRate;
    extern bool  wpnNoFlash;
    extern bool  wpnNoSmoke;
    extern bool  wpnNoShells;

    extern bool  miscBunnyHop;
    extern bool  miscAutoStrafe;
    extern bool  miscLongSlide;
    extern float miscLongSlideStrength;
    extern float miscPlayerSpeed;
    extern bool  miscNoFallDamage;
    extern bool  miscUnlockAll;
    extern bool  miscNoAds;
    extern bool  miscPanicKey;
    extern bool  miscHideWhenClosed;
    extern float miscMenuOpacity;

    extern float menuScale;
    extern bool  animations;

    extern int   uiAccentColor;
    extern int   uiOpenButton;
    extern int   uiPosition;

    void resetToDefaults();
}

#endif
