Source: https://github.com/VendavalSC/Shima
Commit: 5be04e7f7bcc35674b05ca1a26f316c9de08e694
File: Sources/Shima/DeviceActivity.swift
License: GPL-3.0, original license attached. Original copyright retained as provided upstream.
Changes: removed project-specific logging, bounded profiler lifetime, Reduce Motion fallback, update/release AVPlayer resources. System product videos are read in place and not redistributed.

Battery ring geometry also adapted from Sources/Shima/IslandViews.swift BatteryRing at the same commit; reference-specific stroke ratio, centered bolt, below-ring percentage, no added animation, accurate zero/unknown handling.
