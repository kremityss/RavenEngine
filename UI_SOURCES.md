# RavenEngine UI reference sources

This UI refresh keeps RavenEngine branding, settings, runtime state, and open-button behavior while replacing the presentation layer.

References used:

1. `VenerableCode/iOS-Theos-ModMenuTemp-NoJB`
   - Used only as an architectural reference for separating menu rendering, menu state, and no-jailbreak-friendly presentation.
   - The repository currently declares no license, so its source code was not copied into RavenEngine.

2. `silentninjabee/iOS-ImGui-ModMenu-Template`
   - Used as a reference for iOS overlay interaction, touch handling, compact mod-menu layout, and Metal/ImGui presentation patterns.
   - The repository is MIT licensed. No patching/hooking code from that template is required by this UI refresh.

The new RavenEngine implementation is clean-room UIKit/Objective-C++ code and continues to expose the same `RavenMenu` interface and `RavenSettings` integration boundary used by the existing runtime.
