# === CAPsMAN Bulk Upgrade (ac+ax, ROS >= 7.16) ===
# - Auto-detects available utilities (legacy caps-man + wifi capsman)
# - Detects each CAP's architecture (ARM/ARM64/MIPSBE) from board/model
# - Downloads only needed packages for detected architectures
# - Auto-configures package-path if not set (critical for CAP upgrades)
# - Upgrades only outdated CAPs automatically (safe self-reboot)
# - Controller upgrade requires manual reboot (shows commands in summary)
# - Cleans up .npk files after CAPs fetch them
# - Supports ARM, ARM64, MIPSBE, MIPSEL architectures

# ---------------- USER SETTINGS ----------------
:local minFreePerPkgBytes 14000000    ;# ~14 MiB/package safety estimate (base=12MB + buffer for compression/temp)
:local pollInterval 15                ;# check CAP status every N seconds
:local maxWaitTime 300                ;# maximum total wait time (seconds)
:local packageDir "packages"          ;# directory for CAP packages (will be created if needed)
# ------------------------------------------------

# Script-scope state for monitoring and summary
:local allReady false
:local upgradedNames [:toarray ""]
:local upgradedCount 0

# 0) Check which CAPsMAN utilities are available
:local hasLegacyCaps false
:local hasWifiCaps false

:do {
    /caps-man remote-cap print count-only
    :set hasLegacyCaps true
} on-error={
    :set hasLegacyCaps false
}

:do {
    /interface wifi capsman remote-cap print count-only
    :set hasWifiCaps true
} on-error={
    :set hasWifiCaps false
}

:log info ("cap-bulk-upgrade: utilities - legacy caps-man: " . $hasLegacyCaps . ", wifi capsman: " . $hasWifiCaps)

:if (!$hasLegacyCaps and !$hasWifiCaps) do={
    :put "ERROR: No CAPsMAN utilities available (neither legacy nor wifi)"
    :log error "cap-bulk-upgrade: No CAPsMAN utilities available"
    :error "No CAPsMAN utilities found"
}

# 1) Detect latest version on current channel
:do {
    /system/package/update/check-for-updates once
} on-error={
    :log error "cap-bulk-upgrade: failed to contact update server"
    :error "Failed to check for updates"
}
:delay 3s
:local latest [/system/package/update/get latest-version]
:local cur    [/system/package/update/get installed-version]
:local channel [/system/package/update/get channel]

:if (($latest = "") or ($latest = "0.0")) do={
    :put "ERROR: Cannot detect latest version from update server"
    :log error "cap-bulk-upgrade: cannot detect latest-version from update server"
    :error "update server empty"
}

:log info ("cap-bulk-upgrade: latest=" . $latest . " controller=" . $cur . " channel=" . $channel)

# Print banner
:put "================================================================="
:put "CAPsMAN Bulk Upgrade"
:put "================================================================="
:local ctrlStatus ""
:if ($cur = $latest) do={
    :set ctrlStatus " (up-to-date)"
} else={
    :set ctrlStatus (" (needs upgrade)")
}
:put ("Channel: " . $channel . " | Latest: " . $latest . " | Controller: " . $cur . $ctrlStatus)
:put ""

# 2) Discover CAPs
:local capsLegacy [:toarray ""]
:local capsWifi   [:toarray ""]

:if ($hasLegacyCaps) do={
    :set capsLegacy [/caps-man remote-cap find]
    :log info ("cap-bulk-upgrade: discovered legacy CAPs: " . [:len $capsLegacy])
}

:if ($hasWifiCaps) do={
    :set capsWifi [/interface wifi capsman remote-cap find]
    :log info ("cap-bulk-upgrade: discovered wifi CAPs: " . [:len $capsWifi])
}

:local totalCaps ([:len $capsLegacy] + [:len $capsWifi])

# 3) Check who needs upgrade, detect architectures, build discovery table
:local needUpgrade false
:local needArm false
:local needArm64 false
:local needMipsbe false
:local needMipsel false
:local unknownCapsSummary ""
:local capLines [:toarray ""]

# Controller check
:if ($cur != $latest) do={ :set needUpgrade true }

# Legacy CAPS
:if ($hasLegacyCaps) do={
    :foreach c in=$capsLegacy do={
        :do {
            :local v  [/caps-man remote-cap get $c version]
            :local id [/caps-man remote-cap get $c identity]
            :if ($v != $latest) do={
                :set needUpgrade true
                :local board "unknown"
                :do {
                    :set board [/caps-man remote-cap get $c board]
                } on-error={
                    :do {
                        :set board [/caps-man remote-cap get $c model]
                    } on-error={}
                }
                :local archDetected false
                :local arch "unknown"

                # ARM64 whitelist (ax devices + known ARM64 models)
                :if ($board~"ax" or $board~"AX" or $board~"RB5009" or $board~"RB4011" or $board~"L009") do={
                    :set needArm64 true
                    :set archDetected true
                    :set arch "arm64"
                }

                # ARM whitelist (legacy ac, non-ax devices)
                :if (!$archDetected and ($board~"hAP" or $board~"cAP" or $board~"wAP" or $board~"RBwAP" or $board~"RBcAP" or $board~"RBD52G" or $board~"RBD53")) do={
                    :set needArm true
                    :set archDetected true
                    :set arch "arm"
                }

                # MIPSBE whitelist (CRS, RB series)
                :if (!$archDetected and ($board~"CRS" or $board~"RB750" or $board~"RB951" or $board~"RB2011" or $board~"RB3011")) do={
                    :set needMipsbe true
                    :set archDetected true
                    :set arch "mipsbe"
                }

                # Unknown board - default to ARM with warning
                :if (!$archDetected) do={
                    :set needArm true
                    :set arch "arm"
                    :log warning ("cap-bulk-upgrade: CAP " . $id . " board '" . $board . "' unknown, defaulting to ARM")
                }

                :set capLines ($capLines, ("  " . $id . "  " . $arch . "  " . $v . " -> " . $latest))
                :log info ("cap-bulk-upgrade: CAP " . $id . " [" . $board . "/" . $arch . "] needs " . $v . " -> " . $latest)
                :set upgradedCount ($upgradedCount + 1)
                :set upgradedNames ($upgradedNames, $id)
            } else={
                :set capLines ($capLines, ("  " . $id . "  " . $v . " (ok)"))
                :log info ("cap-bulk-upgrade: CAP " . $id . " already on " . $v)
            }
        } on-error={
            :log warning "cap-bulk-upgrade: failed to query legacy CAP (may have disconnected)"
        }
    }
}

# WiFi CAPS
:if ($hasWifiCaps) do={
    :foreach c in=$capsWifi do={
        :do {
            :local v  [/interface wifi capsman remote-cap get $c version]
            :local id [/interface wifi capsman remote-cap get $c identity]
            :if ($v != $latest) do={
                :set needUpgrade true
                :local board "unknown"
                :do {
                    :set board [/interface wifi capsman remote-cap get $c board]
                } on-error={
                    :do {
                        :set board [/interface wifi capsman remote-cap get $c model]
                    } on-error={}
                }
                :local archDetected false
                :local arch "unknown"

                # ARM64 whitelist (ax devices + known ARM64 models)
                :if ($board~"ax" or $board~"AX" or $board~"RB5009" or $board~"RB4011" or $board~"L009") do={
                    :set needArm64 true
                    :set archDetected true
                    :set arch "arm64"
                }

                # ARM whitelist (legacy ac, non-ax devices)
                :if (!$archDetected and ($board~"hAP" or $board~"cAP" or $board~"wAP" or $board~"RBwAP" or $board~"RBcAP" or $board~"RBD52G" or $board~"RBD53")) do={
                    :set needArm true
                    :set archDetected true
                    :set arch "arm"
                }

                # MIPSBE whitelist (CRS, RB series)
                :if (!$archDetected and ($board~"CRS" or $board~"RB750" or $board~"RB951" or $board~"RB2011" or $board~"RB3011")) do={
                    :set needMipsbe true
                    :set archDetected true
                    :set arch "mipsbe"
                }

                # Unknown device - skip with warning
                :if (!$archDetected) do={
                    :log warning ("cap-bulk-upgrade: CAP " . $id . " board '" . $board . "' unknown, SKIPPED")
                    :if ($unknownCapsSummary = "") do={
                        :set unknownCapsSummary ($id . " [" . $board . "]")
                    } else={
                        :set unknownCapsSummary ($unknownCapsSummary . ", " . $id . " [" . $board . "]")
                    }
                    :set capLines ($capLines, ("  " . $id . "  unknown  " . $v . " (SKIPPED)"))
                }

                :if ($archDetected) do={
                    :set capLines ($capLines, ("  " . $id . "  " . $arch . "  " . $v . " -> " . $latest))
                    :log info ("cap-bulk-upgrade: CAP " . $id . " [" . $board . "/" . $arch . "] needs " . $v . " -> " . $latest)
                    :set upgradedCount ($upgradedCount + 1)
                    :set upgradedNames ($upgradedNames, $id)
                }
            } else={
                :set capLines ($capLines, ("  " . $id . "  " . $v . " (ok)"))
                :log info ("cap-bulk-upgrade: CAP " . $id . " already on " . $v)
            }
        } on-error={
            :log warning "cap-bulk-upgrade: failed to query wifi CAP (may have disconnected)"
        }
    }
}

# Print discovery table
:put ("Discovered " . $totalCaps . " CAPs:")
:foreach line in=$capLines do={
    :put $line
}
:put ""

# Early exit if nobody needs an upgrade
:if (!$needUpgrade) do={
    :put "All devices are already on latest version. Nothing to do."
    :log info "cap-bulk-upgrade: all devices on latest; nothing to do"

    # Clean up leftover packages from previous runs
    :local cleanCount 0
    :foreach f in=[/file find where name~($packageDir . "/.*\\.npk")] do={
        /file remove $f
        :set cleanCount ($cleanCount + 1)
    }
    :if ($cleanCount > 0) do={
        :put ("Cleanup: removed " . $cleanCount . " file(s) from " . $packageDir . "/")
    }

    # Restore upgrade-policy in case previous run was interrupted
    :if ($hasLegacyCaps) do={
        :do { /caps-man manager set upgrade-policy=none } on-error={}
    }
    :if ($hasWifiCaps) do={
        :do { /interface wifi capsman set upgrade-policy=none } on-error={}
    }

    :log info "cap-bulk-upgrade: finished"
    :return
}

# 4) Detect controller packages and prepare for downloads
:local ctrlArch [/system resource get architecture-name]
:local ctrlMissingPackages ""
:local pkgArray [:toarray ""]

:if ($needArm or $needArm64 or $needMipsbe or $needMipsel or ($cur != $latest)) do={
    :local installedPkgs [/system package find where disabled=no]
    :foreach pkg in=$installedPkgs do={
        :local pkgName [/system package get $pkg name]
        :if ($pkgName != "routeros") do={
            :set pkgArray ($pkgArray, $pkgName)
        }
    }
    :log info ("cap-bulk-upgrade: controller packages: " . [:tostr $pkgArray])

    # Check free space (errors go to terminal, details to log only)
    :local freeSpace [/system resource get free-hdd-space]
    :local pkgCount ([:len $pkgArray] + 1)
    :local requiredSpace ($pkgCount * $minFreePerPkgBytes)
    :local archCount 0
    :if ($needArm or ($cur != $latest and $ctrlArch = "arm")) do={ :set archCount ($archCount + 1) }
    :if ($needArm64 or ($cur != $latest and $ctrlArch = "arm64")) do={ :set archCount ($archCount + 1) }
    :if ($needMipsbe or ($cur != $latest and $ctrlArch = "mipsbe")) do={ :set archCount ($archCount + 1) }
    :if ($needMipsel or ($cur != $latest and $ctrlArch = "mipsel")) do={ :set archCount ($archCount + 1) }
    :if ($archCount > 1) do={
        :set requiredSpace ($requiredSpace * $archCount)
    }

    :if ($freeSpace < $requiredSpace) do={
        :local freeSpaceMB ($freeSpace / 1000000)
        :local requiredSpaceMB ($requiredSpace / 1000000)
        :put "ERROR: Insufficient storage space"
        :put ("  Required: ~" . $requiredSpaceMB . " MB")
        :put ("  Available: " . $freeSpaceMB . " MB")
        :log error ("cap-bulk-upgrade: insufficient space - need " . $requiredSpaceMB . "MB, have " . $freeSpaceMB . "MB")
        :error "insufficient storage space"
    }
    :log info ("cap-bulk-upgrade: free space OK (" . ($freeSpace / 1000000) . "MB)")

    # Create packages directory if needed (log only, errors to terminal)
    :if ([:len [/file find where name=$packageDir and type="directory"]] = 0) do={
        :do {
            /file/add name=$packageDir type=directory
            :log info ("cap-bulk-upgrade: created directory " . $packageDir)
        } on-error={
            :put ("ERROR: Failed to create directory " . $packageDir)
            :log error ("cap-bulk-upgrade: FAILED to create directory " . $packageDir)
            :error ("Failed to create package directory " . $packageDir)
        }
    }

    # Build architecture array for CAP downloads
    :local archsToDownload [:toarray ""]
    :if ($needArm) do={ :set archsToDownload ($archsToDownload, "arm") }
    :if ($needArm64) do={ :set archsToDownload ($archsToDownload, "arm64") }
    :if ($needMipsbe) do={ :set archsToDownload ($archsToDownload, "mipsbe") }
    :if ($needMipsel) do={ :set archsToDownload ($archsToDownload, "mipsel") }

    # 5) Clean stale packages (old versions) from packages/
    :local staleCount 0
    :foreach f in=[/file find where name~($packageDir . "/.*\\.npk")] do={
        :local fname [/file get $f name]
        :if (!($fname~$latest)) do={
            /file remove $f
            :set staleCount ($staleCount + 1)
            :log info ("cap-bulk-upgrade: removed stale package " . $fname)
        }
    }
    :if ($staleCount > 0) do={
        :put ("Cleaned " . $staleCount . " stale package(s) from " . $packageDir . "/")
        :put ""
    }

    # 6) Download packages for CAP architectures
    # Known CAP wireless packages - download all variants, skip unavailable
    # (CAPs may have different wifi packages than controller: wifi-qcom, wifi-qcom-ac, wireless)
    :local capPkgNames [:toarray ""]
    :set capPkgNames ($capPkgNames, "wifi-qcom")
    :set capPkgNames ($capPkgNames, "wifi-qcom-ac")
    :set capPkgNames ($capPkgNames, "wireless")

    :local baseURL ("https://download.mikrotik.com/routeros/" . $latest . "/")

    :foreach arch in=$archsToDownload do={
        :local archLabel $arch
        :if ($arch = "arm") do={ :set archLabel "ARM" }
        :if ($arch = "arm64") do={ :set archLabel "ARM64" }
        :if ($arch = "mipsbe") do={ :set archLabel "MIPSBE" }
        :if ($arch = "mipsel") do={ :set archLabel "MIPSEL" }
        :put ("Downloading " . $archLabel . " packages to " . $packageDir . "/:")

        :local baseFile ("routeros-" . $latest . "-" . $arch . ".npk")
        :local filePath ($packageDir . "/" . $baseFile)
        :if ([:len [/file find where name=$filePath]] = 0) do={
            :do {
                :local result [/tool fetch url=($baseURL . $baseFile) mode=https as-value output=file dst-path=$filePath]
                :if (($result->"status") = "finished") do={
                    :put ("  " . $baseFile . "  OK")
                    :log info ("cap-bulk-upgrade: downloaded " . $baseFile)
                } else={
                    :put ("  " . $baseFile . "  FAILED")
                    :log error ("cap-bulk-upgrade: CRITICAL - failed to download " . $baseFile . ", status: " . ($result->"status"))
                    :error ("Critical package download failed: " . $baseFile)
                }
            } on-error={
                :put ("  " . $baseFile . "  FAILED")
                :log error ("cap-bulk-upgrade: CRITICAL - exception downloading " . $baseFile)
                :error ("Critical package download failed: " . $baseFile)
            }
        } else={
            :put ("  " . $baseFile . "  cached")
        }

        :foreach pkgName in=$capPkgNames do={
            :local pkgFile ($pkgName . "-" . $latest . "-" . $arch . ".npk")
            :local pkgPath ($packageDir . "/" . $pkgFile)
            :if ([:len [/file find where name=$pkgPath]] = 0) do={
                :do {
                    :local result [/tool fetch url=($baseURL . $pkgFile) mode=https as-value output=file dst-path=$pkgPath]
                    :if (($result->"status") = "finished") do={
                        :put ("  " . $pkgFile . "  OK")
                        :log info ("cap-bulk-upgrade: downloaded " . $pkgFile)
                    } else={
                        :log warning ("cap-bulk-upgrade: " . $pkgFile . " not available for " . $arch)
                    }
                } on-error={
                    :log warning ("cap-bulk-upgrade: " . $pkgFile . " not available for " . $arch)
                }
            } else={
                :put ("  " . $pkgFile . "  cached")
            }
        }
        :put ""
    }

    # 7) Controller staging - download packages directly to root /
    :if ($cur != $latest) do={
        :put ("Downloading controller (" . $ctrlArch . ") packages to /:")
        :local ctrlPkgFile ("routeros-" . $latest . "-" . $ctrlArch . ".npk")
        :local preparedCtrlPkgs 0

        :if ([:len [/file find where name=$ctrlPkgFile]] = 0) do={
            :do {
                :local result [/tool fetch url=($baseURL . $ctrlPkgFile) mode=https as-value output=file dst-path=$ctrlPkgFile]
                :if (($result->"status") = "finished") do={
                    :put ("  " . $ctrlPkgFile . "  OK")
                    :log info ("cap-bulk-upgrade: downloaded " . $ctrlPkgFile)
                    :set preparedCtrlPkgs ($preparedCtrlPkgs + 1)
                } else={
                    :put ("  " . $ctrlPkgFile . "  FAILED")
                    :log error ("cap-bulk-upgrade: CRITICAL - failed to download controller package " . $ctrlPkgFile)
                    :error "Failed to download controller package"
                }
            } on-error={
                :put ("  " . $ctrlPkgFile . "  FAILED")
                :log error ("cap-bulk-upgrade: CRITICAL - exception downloading controller package " . $ctrlPkgFile)
                :error "Failed to download controller package"
            }
        } else={
            :put ("  " . $ctrlPkgFile . "  cached")
            :set preparedCtrlPkgs ($preparedCtrlPkgs + 1)
        }

        :foreach pkgName in=$pkgArray do={
            :local pkgFile ($pkgName . "-" . $latest . "-" . $ctrlArch . ".npk")
            :if ([:len [/file find where name=$pkgFile]] = 0) do={
                :do {
                    :local result [/tool fetch url=($baseURL . $pkgFile) mode=https as-value output=file dst-path=$pkgFile]
                    :if (($result->"status") = "finished") do={
                        :put ("  " . $pkgFile . "  OK")
                        :set preparedCtrlPkgs ($preparedCtrlPkgs + 1)
                    } else={
                        :log warning ("cap-bulk-upgrade: controller addon " . $pkgFile . " not available")
                        :if ($ctrlMissingPackages = "") do={
                            :set ctrlMissingPackages $pkgFile
                        } else={
                            :set ctrlMissingPackages ($ctrlMissingPackages . ", " . $pkgFile)
                        }
                    }
                } on-error={
                    :log warning ("cap-bulk-upgrade: controller addon " . $pkgFile . " not available")
                    :if ($ctrlMissingPackages = "") do={
                        :set ctrlMissingPackages $pkgFile
                    } else={
                        :set ctrlMissingPackages ($ctrlMissingPackages . ", " . $pkgFile)
                    }
                }
            } else={
                :put ("  " . $pkgFile . "  cached")
                :set preparedCtrlPkgs ($preparedCtrlPkgs + 1)
            }
        }
        :put ""
        :log info ("cap-bulk-upgrade: staged " . $preparedCtrlPkgs . " controller package(s)")
        :if ([:len $ctrlMissingPackages] > 0) do={
            :log warning ("cap-bulk-upgrade: controller missing packages: " . $ctrlMissingPackages)
        }
    }
}

# 8) Configure package-path and upgrade-policy (log only, errors to terminal)
:if ($hasLegacyCaps) do={
    :do {
        /caps-man manager set package-path=$packageDir upgrade-policy=suggest-same-version
        :log info ("cap-bulk-upgrade: configured legacy caps-man package-path=" . $packageDir . " upgrade-policy=suggest-same-version")
    } on-error={
        :put "ERROR: Failed to configure legacy caps-man manager"
        :log error "cap-bulk-upgrade: FAILED to configure legacy caps-man manager"
        :error "Failed to configure legacy caps-man manager"
    }
}

:if ($hasWifiCaps) do={
    :do {
        /interface wifi capsman set package-path=$packageDir upgrade-policy=suggest-same-version
        :log info ("cap-bulk-upgrade: configured wifi capsman package-path=" . $packageDir . " upgrade-policy=suggest-same-version")
    } on-error={
        :put "ERROR: Failed to configure wifi capsman manager"
        :log error "cap-bulk-upgrade: FAILED to configure wifi capsman manager"
        :error "Failed to configure wifi capsman manager"
    }
}

# 9) Trigger upgrade on still-connected CAPs (best-effort)
# upgrade-policy change already triggers auto-upgrade on reprovision,
# but we also call upgrade explicitly for CAPs that stayed connected.
:if ($upgradedCount > 0) do={
    :put ("Upgrading " . $upgradedCount . " CAPs...")
    :log info ("cap-bulk-upgrade: triggering upgrade for " . $upgradedCount . " CAP(s)")

    # Re-discover with fresh IDs (policy change may have reprovisioned)
    :local freshLegacy [:toarray ""]
    :local freshWifi [:toarray ""]
    :if ($hasLegacyCaps) do={
        :set freshLegacy [/caps-man remote-cap find]
    }
    :if ($hasWifiCaps) do={
        :set freshWifi [/interface wifi capsman remote-cap find]
    }

    :foreach c in=$freshLegacy do={
        :do {
            :local v [/caps-man remote-cap get $c version]
            :if ($v != $latest) do={
                :local id [/caps-man remote-cap get $c identity]
                :log info ("cap-bulk-upgrade: upgrading legacy CAP " . $id)
                /caps-man remote-cap upgrade $c
            }
        } on-error={}
    }

    :foreach c in=$freshWifi do={
        :do {
            :local v [/interface wifi capsman remote-cap get $c version]
            :if ($v != $latest) do={
                :local id [/interface wifi capsman remote-cap get $c identity]
                :log info ("cap-bulk-upgrade: upgrading wifi CAP " . $id)
                /interface wifi capsman remote-cap upgrade $c
            }
        } on-error={}
    }
} else={
    :if ($totalCaps = 0) do={
        :put "No CAPs detected."
    } else={
        :put "All CAPs already on latest version."
    }
    :log info "cap-bulk-upgrade: no CAPs required upgrade"
}

# 10) Monitor upgraded CAPs by identity
:if ($upgradedCount > 0) do={
    :log info "cap-bulk-upgrade: starting upgrade monitoring"

    :local elapsed 0

    :while (($elapsed < $maxWaitTime) and !$allReady) do={
        :delay ($pollInterval . "s")
        :set elapsed ($elapsed + $pollInterval)

        :local okCount 0

        # Check legacy CAPs by identity
        :if ($hasLegacyCaps) do={
            :foreach c in=[/caps-man remote-cap find] do={
                :do {
                    :local id [/caps-man remote-cap get $c identity]
                    :local v [/caps-man remote-cap get $c version]
                    :foreach name in=$upgradedNames do={
                        :if ($name = $id and $v = $latest) do={
                            :set okCount ($okCount + 1)
                        }
                    }
                } on-error={}
            }
        }

        # Check wifi CAPs by identity
        :if ($hasWifiCaps) do={
            :foreach c in=[/interface wifi capsman remote-cap find] do={
                :do {
                    :local id [/interface wifi capsman remote-cap get $c identity]
                    :local v [/interface wifi capsman remote-cap get $c version]
                    :foreach name in=$upgradedNames do={
                        :if ($name = $id and $v = $latest) do={
                            :set okCount ($okCount + 1)
                        }
                    }
                } on-error={}
            }
        }

        :if ($okCount >= $upgradedCount) do={
            :set allReady true
            :put ("  [" . $elapsed . "s]  " . $okCount . "/" . $upgradedCount . " upgraded - done!")
        } else={
            :put ("  [" . $elapsed . "s]  " . $okCount . "/" . $upgradedCount . " upgraded")
        }
    }

    :if ($allReady) do={
        :log info "cap-bulk-upgrade: all CAPs confirmed upgraded"
    } else={
        :put ("  Timeout (" . $maxWaitTime . "s) - some CAPs may still be upgrading")
        :log warning "cap-bulk-upgrade: timeout waiting for CAPs"
    }
    :put ""

    # Cleanup packages
    :if ($cur = $latest) do={
        :local cleanCount 0
        :foreach f in=[/file find where name~($packageDir . "/.*\\.npk")] do={
            /file remove $f
            :set cleanCount ($cleanCount + 1)
        }
        :if ($cleanCount > 0) do={
            :put ("Cleanup: removed " . $cleanCount . " file(s) from " . $packageDir . "/")
        }
        :log info ("cap-bulk-upgrade: cleaned up " . $cleanCount . " files from " . $packageDir)
    } else={
        :put ("NOTE: Keeping packages in " . $packageDir . "/ for controller upgrade")
        :log info ("cap-bulk-upgrade: keeping packages for pending controller upgrade")
    }
    :put ""
}

# 11) Restore upgrade-policy to none (prevent unintended future auto-upgrades)
:if ($hasLegacyCaps) do={
    :do {
        /caps-man manager set upgrade-policy=none
        :log info "cap-bulk-upgrade: restored legacy caps-man upgrade-policy=none"
    } on-error={}
}
:if ($hasWifiCaps) do={
    :do {
        /interface wifi capsman set upgrade-policy=none
        :log info "cap-bulk-upgrade: restored wifi capsman upgrade-policy=none"
    } on-error={}
}

# 12) Summary
:put "================================================================="
:put "SUMMARY"
:put "================================================================="

:if ($cur != $latest) do={
    :put ("Controller: " . $cur . " -> " . $latest . " (packages ready, reboot required)")
    :if ([:len $ctrlMissingPackages] > 0) do={
        :put ("  WARNING: Missing packages not staged: " . $ctrlMissingPackages)
    }
} else={
    :put ("Controller: " . $cur . " (up-to-date)")
}

:if ($upgradedCount > 0) do={
    :if ($allReady) do={
        :put ("CAPs: " . $upgradedCount . "/" . $upgradedCount . " upgraded to " . $latest)
    } else={
        :put ("CAPs: UPGRADING " . $upgradedCount . " device(s) (check manually)")
    }
} else={
    :if ($totalCaps = 0) do={
        :put "CAPs: none detected"
    } else={
        :put "CAPs: all up-to-date"
    }
}

:if ([:len $unknownCapsSummary] > 0) do={
    :put ("  WARNING: Skipped (unknown board): " . $unknownCapsSummary)
}

:put "================================================================="

:if ($cur != $latest) do={
    :put ""
    :put "To complete controller upgrade, run:"
    :put "  /system reboot"
}

:log info "cap-bulk-upgrade: finished"
