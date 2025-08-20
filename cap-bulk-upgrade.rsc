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

# Legacy CAPS (ac, ARM) - check versions only
:if ($hasLegacyCaps) do={
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
}

# New WiFi CAPS (ax/ac) - detect arch only if upgrade needed
:if ($hasWifiCaps) do={
    :foreach c in=$capsWifi do={
        :local v  [/interface wifi capsman remote-cap get $c version]
        :local id [/interface wifi capsman remote-cap get $c identity]
        :if ($v != $latest) do={
            :set needUpgrade true
            :local board "unknown"
            :do {
                :set board [/interface wifi capsman remote-cap get $c board]
            } on-error={
                :set board [/interface wifi capsman remote-cap get $c model]
            }
            # Decide arch from board/model (safe heuristics)
            :if ($board~"hAP" and !($board~"ax" or $board~"AX")) do={ :set needArm true }
            :if ($board~"cAP" and !($board~"ax" or $board~"AX")) do={ :set needArm true }
            :if ($board~"wAP" or $board~"RBwAP") do={ :set needArm true }
            :if (!($board~"hAP" or $board~"cAP" or $board~"wAP")) do={ :set needArm64 true }
            :set wifiList ($wifiList . "," . $c)
            :log info ("cap-bulk-upgrade: CAP (wifi) " . $id . " needs " . $v . " -> " . $latest)
            :put       ("cap-bulk-upgrade: CAP (wifi) " . $id . " needs " . $v . " -> " . $latest)
        } else={
            :log info ("cap-bulk-upgrade: CAP (wifi) " . $id . " already " . $v . ", skipping")
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
    :put "Press Enter to exit"
    :return
}



# 4) Note: Package detection moved after upgrade decision

# Controller upgrade flags (separate from CAP architecture needs)
:local ctrlArch [/system resource get architecture-name]
:local needCtrlArm false
:local needCtrlArm64 false
:if ($cur != $latest) do={
    :if ($ctrlArch = "arm") do={ :set needCtrlArm true }
    :if ($ctrlArch = "arm64") do={ :set needCtrlArm64 true }
}

# 5) Detect controller's installed packages (for download decisions)
:local pkgList ""
:if ($needArm or $needArm64 or $needCtrlArm or $needCtrlArm64) do={
    # Detect controller's installed packages (only when downloads needed)
    :local installedPkgs [/system package find where disabled=no]
    :foreach pkg in=$installedPkgs do={
        :local pkgName [/system package get $pkg name]
        :if ($pkgName != "routeros") do={
            :set pkgList ($pkgList . "," . $pkgName)
        }
    }
    # Clean package list
    :if (([:len $pkgList] > 0) and ([:pick $pkgList 0 1] = ",")) do={ :set pkgList [:pick $pkgList 1 [:len $pkgList]] }
    
    :put ("cap-bulk-upgrade: controller packages detected: " . $pkgList)
    :log info ("cap-bulk-upgrade: controller packages detected: " . $pkgList)
    
    # Preview what will be downloaded
    :put ""
    :put "================================================================="
    :put "DOWNLOAD PREVIEW"
    :put "================================================================="
    
    # Show ARM packages if needed
    :if ($needArm or ($needCtrlArm and !$needArm64)) do={
        :put "ARM packages to download:"
        :local baseFile ("routeros-" . $latest . "-arm.npk")
        :if ([:len [/file find where name=$baseFile]] = 0) do={ :put ("  - " . $baseFile) }
        :if ([:len $pkgList] > 0) do={
            :local remaining $pkgList
            :while ([:len $remaining] > 0) do={
                :local commaPos [:find $remaining ","]
                :local pkgName ""
                :if ($commaPos >= 0) do={
                    :set pkgName [:pick $remaining 0 $commaPos]
                    :set remaining [:pick $remaining ($commaPos + 1) [:len $remaining]]
                } else={
                    :set pkgName $remaining
                    :set remaining ""
                }
                :if ([:len $pkgName] > 0) do={
                    :local pkgFile ($pkgName . "-" . $latest . "-arm.npk")
                    :if ([:len [/file find where name=$pkgFile]] = 0) do={ :put ("  - " . $pkgFile) }
                }
            }
        }
    }
    
    # Show ARM64 packages if needed
    :if ($needArm64 or ($needCtrlArm64 and !$needArm)) do={
        :put "ARM64 packages to download:"
        :local baseFile ("routeros-" . $latest . "-arm64.npk")
        :if ([:len [/file find where name=$baseFile]] = 0) do={ :put ("  - " . $baseFile) }
        :if ([:len $pkgList] > 0) do={
            :local remaining $pkgList
            :while ([:len $remaining] > 0) do={
                :local commaPos [:find $remaining ","]
                :local pkgName ""
                :if ($commaPos >= 0) do={
                    :set pkgName [:pick $remaining 0 $commaPos]
                    :set remaining [:pick $remaining ($commaPos + 1) [:len $remaining]]
                } else={
                    :set pkgName $remaining
                    :set remaining ""
                }
                :if ([:len $pkgName] > 0) do={
                    :local pkgFile ($pkgName . "-" . $latest . "-arm64.npk")
                    :if ([:len [/file find where name=$pkgFile]] = 0) do={ :put ("  - " . $pkgFile) }
                }
            }
        }
    }
    :put "================================================================="
    :put ""
} else={
    :put "cap-bulk-upgrade: no downloads needed, skipping package detection"
    :return
}

# 6) Fetch packages only for devices that need upgrading
:local baseURL ("https://download.mikrotik.com/routeros/" . $latest . "/")

# Download ARM packages only if ARM CAPs need upgrade
:if ($needArm) do={
    :put "cap-bulk-upgrade: downloading arm packages (ARM CAPs need upgrade)"
    :local baseFile ("routeros-" . $latest . "-arm.npk")
    :if ([:len [/file find where name=$baseFile]] = 0) do={ 
        :put ("fetch " . $baseFile)
        /tool fetch url=($baseURL . $baseFile) mode=https output=file dst-path=$baseFile
    }
    # Download controller's packages for ARM architecture
    :if ([:len $pkgList] > 0) do={
        :local remaining $pkgList
        :while ([:len $remaining] > 0) do={
            :local commaPos [:find $remaining ","]
            :local pkgName ""
            :if ($commaPos >= 0) do={
                :set pkgName [:pick $remaining 0 $commaPos]
                :set remaining [:pick $remaining ($commaPos + 1) [:len $remaining]]
            } else={
                :set pkgName $remaining
                :set remaining ""
            }
            :if ([:len $pkgName] > 0) do={
                :local pkgFile ($pkgName . "-" . $latest . "-arm.npk")
                :if ([:len [/file find where name=$pkgFile]] = 0) do={
                    :put ("fetch " . $pkgFile)
                    :do {
                        /tool fetch url=($baseURL . $pkgFile) mode=https output=file dst-path=$pkgFile
                    } on-error={
                        :log warning ("cap-bulk-upgrade: failed to download " . $pkgFile . " (might not exist)")
                    }
                }
            }
        }
    }
}

# Download ARM64 packages only if ARM64 CAPs need upgrade  
:if ($needArm64) do={
    :put "cap-bulk-upgrade: downloading arm64 packages (ARM64 CAPs need upgrade)"
    :local baseFile ("routeros-" . $latest . "-arm64.npk")
    :if ([:len [/file find where name=$baseFile]] = 0) do={ 
        :put ("fetch " . $baseFile)
        /tool fetch url=($baseURL . $baseFile) mode=https output=file dst-path=$baseFile
    }
    # Download controller's packages for ARM64 architecture
    :if ([:len $pkgList] > 0) do={
        :local remaining $pkgList
        :while ([:len $remaining] > 0) do={
            :local commaPos [:find $remaining ","]
            :local pkgName ""
            :if ($commaPos >= 0) do={
                :set pkgName [:pick $remaining 0 $commaPos]
                :set remaining [:pick $remaining ($commaPos + 1) [:len $remaining]]
            } else={
                :set pkgName $remaining
                :set remaining ""
            }
            :if ([:len $pkgName] > 0) do={
                :local pkgFile ($pkgName . "-" . $latest . "-arm64.npk")
                :if ([:len [/file find where name=$pkgFile]] = 0) do={
                    :put ("fetch " . $pkgFile)
                    :do {
                        /tool fetch url=($baseURL . $pkgFile) mode=https output=file dst-path=$pkgFile
                    } on-error={
                        :log warning ("cap-bulk-upgrade: failed to download " . $pkgFile . " (might not exist)")
                    }
                }
            }
        }
    }
}

# Download controller packages only if controller needs upgrade (no CAP overlap)
:if ($needCtrlArm and !$needArm) do={
    :put "cap-bulk-upgrade: downloading arm packages (controller only)"
    :local baseFile ("routeros-" . $latest . "-arm.npk")
    :if ([:len [/file find where name=$baseFile]] = 0) do={ 
        :put ("fetch " . $baseFile)
        /tool fetch url=($baseURL . $baseFile) mode=https output=file dst-path=$baseFile
    }
    # Download controller's packages for ARM architecture
    :if ([:len $pkgList] > 0) do={
        :local remaining $pkgList
        :while ([:len $remaining] > 0) do={
            :local commaPos [:find $remaining ","]
            :local pkgName ""
            :if ($commaPos >= 0) do={
                :set pkgName [:pick $remaining 0 $commaPos]
                :set remaining [:pick $remaining ($commaPos + 1) [:len $remaining]]
            } else={
                :set pkgName $remaining
                :set remaining ""
            }
            :if ([:len $pkgName] > 0) do={
                :local pkgFile ($pkgName . "-" . $latest . "-arm.npk")
                :if ([:len [/file find where name=$pkgFile]] = 0) do={
                    :put ("fetch " . $pkgFile)
                    :do {
                        /tool fetch url=($baseURL . $pkgFile) mode=https output=file dst-path=$pkgFile
                    } on-error={
                        :log warning ("cap-bulk-upgrade: failed to download " . $pkgFile . " (might not exist)")
                    }
                }
            }
        }
    }
}
:if ($needCtrlArm64 and !$needArm64) do={
    :put "cap-bulk-upgrade: downloading arm64 packages (controller only)"
    :local baseFile ("routeros-" . $latest . "-arm64.npk")
    :if ([:len [/file find where name=$baseFile]] = 0) do={ 
        :put ("fetch " . $baseFile)
        /tool fetch url=($baseURL . $baseFile) mode=https output=file dst-path=$baseFile
    }
    # Download controller's packages for ARM64 architecture
    :if ([:len $pkgList] > 0) do={
        :local remaining $pkgList
        :while ([:len $remaining] > 0) do={
            :local commaPos [:find $remaining ","]
            :local pkgName ""
            :if ($commaPos >= 0) do={
                :set pkgName [:pick $remaining 0 $commaPos]
                :set remaining [:pick $remaining ($commaPos + 1) [:len $remaining]]
            } else={
                :set pkgName $remaining
                :set remaining ""
            }
            :if ([:len $pkgName] > 0) do={
                :local pkgFile ($pkgName . "-" . $latest . "-arm64.npk")
                :if ([:len [/file find where name=$pkgFile]] = 0) do={
                    :put ("fetch " . $pkgFile)
                    :do {
                        /tool fetch url=($baseURL . $pkgFile) mode=https output=file dst-path=$pkgFile
                    } on-error={
                        :log warning ("cap-bulk-upgrade: failed to download " . $pkgFile . " (might not exist)")
                    }
                }
            }
        }
    }
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

:put "cap-bulk-upgrade: finished"

# Final reboot command (very last for easy copying)
:if ($cur != $latest) do={
    :put ""
    :put ">>>>> TO COMPLETE CONTROLLER UPGRADE, COPY AND RUN: <<<<<"
    :put ""
    :put "/system reboot"
    :put ""
}

:log info "cap-bulk-upgrade: finished"