# === CAPsMAN Bulk Upgrade (ac+ax, ROS >= 7.16) ===
# - Checks who needs upgrade first (controller + CAPs)
# - Only then checks disk space and downloads needed packages
# - Upgrades only outdated CAPs (no needless reboots)
# - Optional controller auto-reboot via flag
# - Cleans up .npk files after CAPs fetch them

# ---------------- USER SETTINGS ----------------
:local safeControllerReboot true     ;# true = do NOT auto-reboot controller; prints commands instead
:local minFreePerPkgBytes 15000000   ;# ~15 MiB/package safety estimate
:local cleanupDelay "120s"           ;# wait before removing .npk files
# ------------------------------------------------

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

# 2) Discover CAPs in both managers
:local capsLegacy [/caps-man remote-cap find]
:local capsWifi   [/interface wifi capsman remote-cap find]
:log info ("cap-bulk-upgrade: discovered CAPs — legacy=" . [:len $capsLegacy] . ", wifi=" . [:len $capsWifi])
:put       ("cap-bulk-upgrade: discovered CAPs — legacy=" . [:len $capsLegacy] . ", wifi=" . [:len $capsWifi])

# 3) Check who needs an upgrade (and which arch packages we’ll need)
:local needUpgrade false
:local needArm false
:local needArm64 false
:local legList ""
:local wifiList ""

# Controller check
:if ($cur != $latest) do={ :set needUpgrade true }

# Legacy CAPS (ac, ARM)
:foreach c in=$capsLegacy do={
    :local v  [/caps-man remote-cap get $c version]
    :local id [/caps-man remote-cap get $c identity]
    :if ($v != $latest) do={
        :set needUpgrade true
        :set needArm true
        :set legList ($legList . "," . $c)
        :log info ("cap-bulk-upgrade: CAP (legacy) " . $id . " needs " . $v . " -> " . $latest)
        :put       ("cap-bulk-upgrade: CAP (legacy) " . $id . " needs " . $v . " -> " . $latest)
    } else={
        :log info ("cap-bulk-upgrade: CAP (legacy) " . $id . " already " . $v . ", skipping")
    }
}

# New WiFi CAPS (ax, ARM64)
:foreach c in=$capsWifi do={
    :local v  [/interface wifi capsman remote-cap get $c version]
    :local id [/interface wifi capsman remote-cap get $c identity]
    :if ($v != $latest) do={
        :set needUpgrade true
        :set needArm64 true
        :set wifiList ($wifiList . "," . $c)
        :log info ("cap-bulk-upgrade: CAP (wifi) " . $id . " needs " . $v . " -> " . $latest)
        :put       ("cap-bulk-upgrade: CAP (wifi) " . $id . " needs " . $v . " -> " . $latest)
    } else={
        :log info ("cap-bulk-upgrade: CAP (wifi) " . $id . " already " . $v . ", skipping")
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

# 7) Controller upgrade (optional) — only if outdated
:if ($cur != $latest) do={
    :if ($safeControllerReboot = true) do={
        :put ("cap-bulk-upgrade: controller outdated (" . $cur . " -> " . $latest . "), NOT auto-rebooting (safe mode).")
        :put ("To upgrade controller now, run:")
        :if ($ctrlArch = "arm")   do={ :put ("/system package add path=" . $baseArm) }
        :if ($ctrlArch = "arm64") do={ :put ("/system package add path=" . $baseArm64) }
        :put ("/system reboot")
        :log info "cap-bulk-upgrade: controller upgrade deferred (safeControllerReboot=true)"
    } else{
        :log info "cap-bulk-upgrade: installing controller package and rebooting now"
        :if ($ctrlArch = "arm")   do={ /system package add path=$baseArm }
        :if ($ctrlArch = "arm64") do={ /system package add path=$baseArm64 }
        # Schedule one-time post-reboot cleanup (optional)
        /system scheduler add name="cap-post-cleanup" start-time=startup on-event="/delay $cleanupDelay; /file remove [/file find where name~\".*\\\\.npk\"]; /system scheduler remove cap-post-cleanup;"
        /system reboot
        :return
    }
}

# 8) Upgrade only CAPs that need it (controller is latest OR safe mode chosen)
:if ([:len $legList] > 0) do={
    :log info ("cap-bulk-upgrade: upgrading legacy CAPs: " . $legList)
    :put       ("cap-bulk-upgrade: upgrading legacy CAPs: " . $legList)
    /caps-man remote-cap upgrade numbers=$legList
}
:if ([:len $wifiList] > 0) do={
    :log info ("cap-bulk-upgrade: upgrading wifi CAPs: " . $wifiList)
    :put       ("cap-bulk-upgrade: upgrading wifi CAPs: " . $wifiList)
    /interface wifi capsman remote-cap upgrade numbers=$wifiList
}
:if (([:len $legList] = 0) and ([:len $wifiList] = 0)) do={
    :log info "cap-bulk-upgrade: no CAPs required upgrade"
    :put       "cap-bulk-upgrade: no CAPs required upgrade"
}

# 9) Cleanup after grace period (so CAPs can download)
:log info ("cap-bulk-upgrade: waiting " . $cleanupDelay . " before cleanup")
:delay $cleanupDelay
/file remove [/file find where name~".*\\.npk"]
:log info "cap-bulk-upgrade: cleaned up .npk files on controller"
:put       "cap-bulk-upgrade: cleaned up .npk files on controller"

:log info "cap-bulk-upgrade: finished"
:put       "cap-bulk-upgrade: finished"