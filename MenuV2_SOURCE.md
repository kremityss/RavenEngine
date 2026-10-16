# Raven UI v2 source of truth

`Src/MenuV2.mm` is the RavenEngine UI v2 implementation used by the UI refresh branch.

The build workflow restores this file over `Src/Menu.mm` after `write_tree.py` regeneration so the generated source tree cannot silently revert to the legacy menu.

The intended permanent source-of-truth mapping is `Menu_fixed.mm` -> `Src/Menu.mm`, matching the existing `write_tree.py` override convention.
