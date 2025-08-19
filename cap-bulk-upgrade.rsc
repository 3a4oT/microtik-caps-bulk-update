# === CAPsMAN Bulk Upgrade (ac+ax, ROS >= 7.16) ===
# - Auto-detects available utilities (legacy caps-man + wifi capsman)
# - Detects each CAP's architecture (ARM/ARM64) from board/model
# - Downloads only needed packages for detected architectures
# - Upgrades only outdated CAPs automatically (safe self-reboot)
# - Controller upgrade requires manual reboot (shows commands in summary)
# - Cleans up .npk files after CAPs fetch them

# ---------------- USER SETTINGS ----------------
:local minFreePerPkgBytes 14000000    ;# ~14 MiB/package safety estimate (base=12MB + buffer for compression/temp)
:local cleanupDelay "120s"           ;# wait before removing .npk files
# ------------------------------------------------

# 0) Check which CAPsMAN utilities are available
:local hasLegacyCaps false
:local hasWifiCaps false

# Check for legacy caps-man
:do {
    /caps-man remote-cap print count-only
    :set hasLegacyCaps true
} on-error={
    :set hasLegacyCaps false
}

# Check for new wifi capsman
:do {
    /interface wifi capsman remote-cap print count-only
    :set hasWifiCaps true
} on-error={
    :set hasWifiCaps false
}

:put ("cap-bulk-upgrade: Available utilities - legacy caps-man: " . $hasLegacyCaps . ", wifi capsman: " . $hasWifiCaps)
:log info ("cap-bulk-upgrade: Available utilities - legacy caps-man: " . $hasLegacyCaps . ", wifi capsman: " . $hasWifiCaps)

# Exit if no CAPsMAN utilities available
:if (!$hasLegacyCaps and !$hasWifiCaps) do={
    :put "cap-bulk-upgrade: ERROR - No CAPsMAN utilities available (neither legacy nor wifi)"
    :log error "cap-bulk-upgrade: No CAPsMAN utilities available"
    :error "No CAPsMAN utilities found"
}

# 1) Detect latest version on current channel (no channel change)
/system package update check-for-updates
:local latest [/system package update get latest-version]
:local cur    [/system package update get installed-version]

:if (($latest = "") or ($latest = "0.0")) do={
    :put "cap-bulk-upgrade: ERROR cannot detect latest-version from update server"
    :log error "cap-bulk-upgrade: cannot detect latest-version from update server"
    :error "update server empty"
}

:put ("cap-bulk-upgrade: latest=" . $latest . "  controller=" . $cur)
:log info ("cap-bulk-upgrade: latest=" . $latest . "  controller=" . $cur)

# 2) Discover CAPs in both managers (only if available)
:local capsLegacy [:toarray ""]
:local capsWifi   [:toarray ""]

:if ($hasLegacyCaps) do={
    :set capsLegacy [/caps-man remote-cap find]
    :log info ("cap-bulk-upgrade: discovered legacy CAPs: " . [:len $capsLegacy])
    :put ("cap-bulk-upgrade: discovered legacy CAPs: " . [:len $capsLegacy])
}

:if ($hasWifiCaps) do={
    :set capsWifi [/interface wifi capsman remote-cap find]
    :log info ("cap-bulk-upgrade: discovered wifi CAPs: " . [:len $capsWifi])
    :put ("cap-bulk-upgrade: discovered wifi CAPs: " . [:len $capsWifi])
}

# 3) Check who needs an upgrade (and which arch packages we’ll need)
:local needUpgrade false
:local needArm false
:local needArm64 false
:local legList ""
:local wifiList ""

# Controller check
:if ($cur != $latest) do={ :set needUpgrade true }

# Legacy CAPS - detect actual architecture per CAP
:if ($hasLegacyCaps) do={
    :foreach c in=$capsLegacy do={
        :local v  [/caps-man remote-cap get $c version]
        :local id [/caps-man remote-cap get $c identity]
        
        # Try to get board name with error handling
        :local board "unknown"
        :do {
            :set board [/caps-man remote-cap get $c board]
        } on-error={
            :set board [/caps-man remote-cap get $c model]
        }
        
        # Determine architecture from board name
        :local arch "arm"  ;# default for legacy
        # ARM64 boards: RB5009, hAP ax series, etc.
        :if ($board~"RB5009" or $board~"ax" or $board~"AX" or $board~"RB4011" or $board~"RB3011") do={ :set arch "arm64" }
        
        :if ($v != $latest) do={
            :set needUpgrade true
            :if ($arch = "arm") do={ :set needArm true }
            :if ($arch = "arm64") do={ :set needArm64 true }
            :set legList ($legList . "," . $c)
            :log info ("cap-bulk-upgrade: CAP (legacy) " . $id . " [" . $board . "/" . $arch . "] needs " . $v . " -> " . $latest)
            :put       ("cap-bulk-upgrade: CAP (legacy) " . $id . " [" . $board . "/" . $arch . "] needs " . $v . " -> " . $latest)
        } else={
            :log info ("cap-bulk-upgrade: CAP (legacy) " . $id . " [" . $board . "/" . $arch . "] already " . $v . ", skipping")
        }
    }
}

# New WiFi CAPS - detect actual architecture per CAP  
:if ($hasWifiCaps) do={
    :foreach c in=$capsWifi do={
        :local v  [/interface wifi capsman remote-cap get $c version]
        :local id [/interface wifi capsman remote-cap get $c identity]
        
        # Try to get board name with error handling
        :local board "unknown"
        :do {
            :set board [/interface wifi capsman remote-cap get $c board]
        } on-error={
            :set board [/interface wifi capsman remote-cap get $c model]
        }
        
        # Determine architecture from board name
        :local arch "arm64"  ;# default for wifi (ax devices)
        # ARM boards: older AC devices, some special cases
        :if ($board~"hAP" and !($board~"ax" or $board~"AX")) do={ :set arch "arm" }
        :if ($board~"cAP" and !($board~"ax" or $board~"AX")) do={ :set arch "arm" }
        :if ($board~"wAP" or $board~"RBwAP") do={ :set arch "arm" }
        
        :if ($v != $latest) do={
            :set needUpgrade true
            :if ($arch = "arm") do={ :set needArm true }
            :if ($arch = "arm64") do={ :set needArm64 true }
            :set wifiList ($wifiList . "," . $c)
            :log info ("cap-bulk-upgrade: CAP (wifi) " . $id . " [" . $board . "/" . $arch . "] needs " . $v . " -> " . $latest)
            :put       ("cap-bulk-upgrade: CAP (wifi) " . $id . " [" . $board . "/" . $arch . "] needs " . $v . " -> " . $latest)
        } else={
            :log info ("cap-bulk-upgrade: CAP (wifi) " . $id . " [" . $board . "/" . $arch . "] already " . $v . ", skipping")
        }
    }
}

# Normalize lists
:if (([:len $legList]  > 0) and ([:pick $legList  0 1] = ",")) do={ :set legList  [:pick $legList  1 [:len $legList]] }
:if (([:len $wifiList] > 0) and ([:pick $wifiList 0 1] = ",")) do={ :set wifiList [:pick $wifiList 1 [:len $wifiList]] }

# Early exit if nobody needs an upgrade
:if (!$needUpgrade) do={
    :put "cap-bulk-upgrade: all devices are already on latest; nothing to do."
    :log info "cap-bulk-upgrade: all devices are already on latest; nothing to do."
    :return
}

# 4) Decide which package files are needed (version-first filenames)
:local baseArm   ("routeros-" . $latest . "-arm.npk")
:local baseArm64 ("routeros-" . $latest . "-arm64.npk")
:local wifiAcArm   ("wifi-qcom-ac-" . $latest . "-arm.npk")    ;# ac (wave2)
:local wirelessArm ("wireless-"     . $latest . "-arm.npk")    ;# legacy fallback for ac
:local wifiAxArm64 ("wifi-qcom-"    . $latest . "-arm64.npk")  ;# ax
:local caleaArm    ("calea-"        . $latest . "-arm.npk")
:local caleaArm64  ("calea-"        . $latest . "-arm64.npk")

# Controller arch base package (if controller is outdated)
:local ctrlArch [/system resource get architecture-name]
:local needCtrlArm false
:local needCtrlArm64 false
:if ($cur != $latest) do={
    :if ($ctrlArch = "arm")   do={ :set needCtrlArm true }
    :if ($ctrlArch = "arm64") do={ :set needCtrlArm64 true }
}

# 5) Disk space estimate BEFORE any download (count only missing files)
:local pkgCount 0
:if ($needArm) do={
    :if ([:len [/file find where name=$baseArm]]   = 0) do={ :set pkgCount ($pkgCount + 1) }
    :if ([:len [/file find where name=$wifiAcArm]] = 0) do={ :set pkgCount ($pkgCount + 1) }
    :if ([:len [/file find where name=$wirelessArm]] = 0) do={ :set pkgCount ($pkgCount + 1) }
    :if ([:len [/file find where name=$caleaArm]]  = 0) do={ :set pkgCount ($pkgCount + 1) }
}
:if ($needArm64) do={
    :if ([:len [/file find where name=$baseArm64]]   = 0) do={ :set pkgCount ($pkgCount + 1) }
    :if ([:len [/file find where name=$wifiAxArm64]] = 0) do={ :set pkgCount ($pkgCount + 1) }
    :if ([:len [/file find where name=$caleaArm64]]  = 0) do={ :set pkgCount ($pkgCount + 1) }
}
:if ($needCtrlArm and !$needArm) do={
    :if ([:len [/file find where name=$baseArm]]   = 0) do={ :set pkgCount ($pkgCount + 1) }
}
:if ($needCtrlArm64 and !$needArm64) do={
    :if ([:len [/file find where name=$baseArm64]] = 0) do={ :set pkgCount ($pkgCount + 1) }
}

:local needBytes ($pkgCount * $minFreePerPkgBytes)
:local freeBytes [/system resource get free-hdd-space]
:if ($freeBytes < $needBytes) do={
    :put ("cap-bulk-upgrade: insufficient space — available " . ($freeBytes / 1048576) . " MiB, need at least " . ($needBytes / 1048576) . " MiB for ~" . $pkgCount . " package(s). Free space and re-run.")
    :log error ("cap-bulk-upgrade: insufficient space (" . ($freeBytes / 1048576) . " MiB < " . ($needBytes / 1048576) . " MiB)")
    :error "insufficient space"
}

# 6) Fetch only missing packages
:local baseURL ("https://download.mikrotik.com/routeros/" . $latest . "/")

:if ($needArm) do={
    :if ([:len [/file find where name=$baseArm]]   = 0) do={ :put ("fetch " . $baseArm);   /tool fetch url=($baseURL . $baseArm)   mode=https output=file dst-path=$baseArm }
    :if ([:len [/file find where name=$wifiAcArm]] = 0) do={ :put ("fetch " . $wifiAcArm); /tool fetch url=($baseURL . $wifiAcArm) mode=https output=file dst-path=$wifiAcArm }
    :if ([:len [/file find where name=$wirelessArm]] = 0) do={ :put ("fetch " . $wirelessArm); /tool fetch url=($baseURL . $wirelessArm) mode=https output=file dst-path=$wirelessArm }
    :if ([:len [/file find where name=$caleaArm]]  = 0) do={ :put ("fetch " . $caleaArm);  /tool fetch url=($baseURL . $caleaArm)  mode=https output=file dst-path=$caleaArm }
}
:if ($needArm64) do={
    :if ([:len [/file find where name=$baseArm64]]   = 0) do={ :put ("fetch " . $baseArm64);   /tool fetch url=($baseURL . $baseArm64)   mode=https output=file dst-path=$baseArm64 }
    :if ([:len [/file find where name=$wifiAxArm64]] = 0) do={ :put ("fetch " . $wifiAxArm64); /tool fetch url=($baseURL . $wifiAxArm64) mode=https output=file dst-path=$wifiAxArm64 }
    :if ([:len [/file find where name=$caleaArm64]]  = 0) do={ :put ("fetch " . $caleaArm64);  /tool fetch url=($baseURL . $caleaArm64)  mode=https output=file dst-path=$caleaArm64 }
}
:if ($needCtrlArm and !$needArm) do={
    :if ([:len [/file find where name=$baseArm]] = 0) do={ :put ("fetch " . $baseArm); /tool fetch url=($baseURL . $baseArm) mode=https output=file dst-path=$baseArm }
}
:if ($needCtrlArm64 and !$needArm64) do={
    :if ([:len [/file find where name=$baseArm64]] = 0) do={ :put ("fetch " . $baseArm64); /tool fetch url=($baseURL . $baseArm64) mode=https output=file dst-path=$baseArm64 }
}

# 7) Controller upgrade - note if needed
:if ($cur != $latest) do={
    :put ("cap-bulk-upgrade: controller needs upgrade (" . $cur . " -> " . $latest . "), package downloaded")
    :log info ("cap-bulk-upgrade: controller upgrade ready (v" . $cur . " -> v" . $latest . ")")
}

# 8) Upgrade CAPs automatically (they can reboot safely)
:if ($hasLegacyCaps and ([:len $legList] > 0)) do={
    :put ("cap-bulk-upgrade: upgrading legacy CAPs: " . $legList)
    :log info ("cap-bulk-upgrade: upgrading legacy CAPs: " . $legList)
    /caps-man remote-cap upgrade numbers=$legList
}
:if ($hasWifiCaps and ([:len $wifiList] > 0)) do={
    :put ("cap-bulk-upgrade: upgrading wifi CAPs: " . $wifiList)
    :log info ("cap-bulk-upgrade: upgrading wifi CAPs: " . $wifiList)
    /interface wifi capsman remote-cap upgrade numbers=$wifiList
}
:if (([:len $legList] = 0) and ([:len $wifiList] = 0)) do={
    # Check if any CAPs were discovered at all
    :if (([:len $capsLegacy] = 0) and ([:len $capsWifi] = 0)) do={
        :put "cap-bulk-upgrade: no CAPs detected"
        :log info "cap-bulk-upgrade: no CAPs found in system"
    } else={
        :put "cap-bulk-upgrade: all CAPs already on latest version"
        :log info "cap-bulk-upgrade: no CAPs required upgrade"
    }
}

# 9) Cleanup and final status
:if (([:len $legList] > 0) or ([:len $wifiList] > 0)) do={
    :put ("cap-bulk-upgrade: waiting " . $cleanupDelay . " for CAPs to download packages...")
    :log info ("cap-bulk-upgrade: waiting " . $cleanupDelay . " before cleanup")
    :delay $cleanupDelay
    /file remove [/file find where name~".*\\.npk"]
    :put "cap-bulk-upgrade: cleaned up .npk files"
    :log info "cap-bulk-upgrade: cleaned up .npk files on controller"
}

:put ""
:put "================================================================="
:put "UPGRADE SUMMARY"
:put "================================================================="

# Controller status and commands
:if ($cur != $latest) do={
    :put ("Controller: " . $cur . " -> " . $latest . " (READY - manual reboot required)")
    :put ""
    :put "To complete controller upgrade, copy and run:"
    :put "/system reboot"
    :put ""
    :put ("RouterOS will automatically install: routeros-" . $latest . "-" . $ctrlArch . ".npk")
    :put ""
    :put "NOTE: Controller reboot does NOT affect CAP operations."
} else={
    :put ("Controller: " . $cur . " (UP-TO-DATE)")
}

# CAP status
:if (([:len $legList] > 0) or ([:len $wifiList] > 0)) do={
    :put "CAPs: UPGRADING (automatic, will complete shortly)"
} else={
    # Check if any CAPs were discovered at all
    :if (([:len $capsLegacy] = 0) and ([:len $capsWifi] = 0)) do={
        :put "CAPs: No CAPs detected"
    } else={
        :put "CAPs: UP-TO-DATE"
    }
}

:put "================================================================="

:log info "cap-bulk-upgrade: finished"
:put "cap-bulk-upgrade: finished"