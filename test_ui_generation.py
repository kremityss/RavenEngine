#!/usr/bin/env python3
"""Static regression checks for Raven's generated UI/control wiring."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
GENERATOR = ROOT / "write_tree.py"

with tempfile.TemporaryDirectory() as td:
    subprocess.run(["python3", str(GENERATOR)], cwd=td, check=True)
    menu = (Path(td) / "Src" / "Menu.mm").read_text()
    esp = (Path(td) / "Src" / "ESP.mm").read_text()
    aimbot = (Path(td) / "Src" / "Aimbot.mm").read_text()
    settings = (Path(td) / "Src" / "Settings.mm").read_text()
    license_header = (Path(td) / "Src" / "LicenseClient.h").read_text()
    license_impl = (Path(td) / "Src" / "LicenseClient.mm").read_text()

    required_menu_fragments = [
        "self.ball.hidden  = (RavenSettings::uiOpenButton == 2);",
        "RavenSettings::miscMenuOpacity / 100.0",
        "- (void)reloadActiveTab",
        "sub.frame = CGRectMake(14, 26, MAX(40, w - 28), 18);",
        "sub.frame = CGRectMake(MAX(14, w - 126), 2, 112, 24);",
        "RavenSettings::save();",
    ]
    for fragment in required_menu_fragments:
        assert fragment in menu, f"missing menu wiring: {fragment}"

    required_runtime_fragments = [
        "if (RavenSettings::espBox) {",
        "drawHexBox:boxRect",
        "drawRoundBox:boxRect",
        "drawGradientBox:boxRect",
        "drawEliteBox:boxRect",
        "RavenSettings::aimMaxDist > 0.0f",
    ]
    for fragment in required_runtime_fragments[:-1]:
        assert fragment in esp, f"missing runtime wiring: {fragment}"
    assert required_runtime_fragments[-1] in aimbot, f"missing runtime wiring: {required_runtime_fragments[-1]}"

    for name in ["aimPrediction", "espSkeleton", "visFovCircle", "wpnRapidFire", "miscBunnyHop"]:
        assert name in settings, f"missing persisted setting: {name}"

    assert "Src/LicenseClient.mm" in (Path(td) / "Makefile").read_text()
    assert "validateStoredAsync" in license_header and "deviceFingerprint" in license_header
    assert "license.validate?batch=1" in license_impl
    assert "NSUserDefaults" in license_impl and "CC_SHA256" in license_impl

print("UI generation and control wiring checks passed")
