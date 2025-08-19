# CAPsMAN Bulk Upgrade (ac + ax, RouterOS ≥ 7.16) — README (UA)

Цей скрипт оновлює **контролер** MikroTik (CAPsMAN) та **CAP-пристрої** до **останньої** версії RouterOS на **поточному** каналі оновлень однією командою. Підтримує змішане оточення **ac** (ARM, legacy `/caps-man`) і **ax** (ARM64, новий `/interface wifi capsman`).

Скрипт **автоматично визначає** доступні утиліти, завантажує потрібні пакети та показує зручне **UPGRADE SUMMARY** з командами в кінці.

🔗 **Скрипт**: [`cap-bulk-upgrade.rsc`](cap-bulk-upgrade.rsc)

## 🛠 Встановлення (на основному контролері)

1. Відкрийте **WinBox / WebFig** → **System → Scripts → +**.  
2. **Name**: `cap-bulk-upgrade`.  
3. Увімкніть Policies: **read, write, test, policy, ftp**.  
4. Скопіюйте код скрипта: **[cap-bulk-upgrade.rsc](cap-bulk-upgrade.rsc)** → Вставте в RouterOS → **OK**.  
   📝 *Порада: Натисніть на лінк, потім Ctrl+A → Ctrl+C для копіювання всього скрипта.*

---

## ▶️ Запуск (на основному контролері)

- Через WinBox: **System → Scripts → cap-bulk-upgrade → Run Script**  

АБО 

- Через термінал:
   ```rsc
   /system script run cap-bulk-upgrade
   ```

---

---

## 🚀 Можливості

- Визначає `latest-version` від update-сервера (канал **не** змінюється).
- Перевіряє версію **контролера** і **кожного CAP-а** (ac і ax окремо).
- Якщо **всі на останній версії** — **нічого не завантажує** і завершує роботу.
- Якщо потрібне оновлення:
  - Перевіряє **вільний простір** на контролері; якщо мало — зупиняється з чітким повідомленням.
  - Завантажує **рівно ті пакети**, що потрібні для присутніх архітектур:
    - База: `routeros-<ver>-arm.npk`, `routeros-<ver>-arm64.npk`
    - Драйвери Wi-Fi: `wifi-qcom-ac-<ver>-arm.npk` (ac), `wireless-<ver>-arm.npk` (legacy для ac), `wifi-qcom-<ver>-arm64.npk` (ax)
    - Додатково: `calea-<ver>-arm(.npk)` і `-arm64` (запобігає помилці *“no such file”*, якщо CAP має CALEA)
- Оновлює **лише застарілі CAP-и** (вони перезавантажуються самі).
- Оновлення **контролера** — завжди вимагає ручного перезавантаження (безпечно).
- Після паузи видаляє всі `.npk` з контролера.
- Логи **англійською** у термінал та **System → Log**.

---

## ✅ Вимоги

- RouterOS **7.16+** на контролері (перевірено на 7.19.4).
- CAP-и видимі під `/caps-man` (ac) та/або `/interface wifi capsman` (ax).
- На контролері працює **DNS/Інтернет**.
- Політики скрипта: **read, write, test, policy, ftp** (WinBox → System → Scripts → ваш скрипт → Policies).

---

## ⚙️ Налаштування (на початку скрипта)

- `:local minFreePerPkgBytes 15000000` — оцінка потрібного місця (≈15 МіБ на пакет, використовується в підрахунку перед завантаженням).

- `:local cleanupDelay "120s"` — час на завантаження пакетів CAP-ами перед видаленням `.npk`.

## 📋 Поведінка скрипта

- **CAP-и** оновлюються **автоматично** (безпечно, самі керують перезавантаженням).
- **Контролер** завжди вимагає **ручного перезавантаження** для безпеки.
- В кінці скрипт показує **UPGRADE SUMMARY** з усіма потрібними командами.
- Для оновлення контролера просто запустіть: `/system reboot` (RouterOS автоматично встановить завантажений .npk файл).

## 📺 Приклад виводу

```
cap-bulk-upgrade: Available utilities - legacy caps-man: false, wifi capsman: true
cap-bulk-upgrade: latest=7.19.4  controller=7.17.2
cap-bulk-upgrade: discovered wifi CAPs: 0
fetch routeros-7.19.4-arm64.npk
[...завантаження...]
cap-bulk-upgrade: controller needs upgrade (7.17.2 -> 7.19.4), package downloaded
cap-bulk-upgrade: no CAPs detected
cap-bulk-upgrade: finished

=================================================================
UPGRADE SUMMARY
=================================================================

Controller: 7.17.2 -> 7.19.4 (READY - manual reboot required)

To complete controller upgrade, copy and run:
/system reboot

RouterOS will automatically install: routeros-7.19.4-arm64.npk

NOTE: Controller reboot does NOT affect CAP operations.

CAPs: No CAPs detected

=================================================================
```


## 🧰 Усунення несправностей

- **“cannot detect latest-version”** → перевірте DNS/Інтернет на контролері:
   ```rsc
   /ping 8.8.8.8 count=3
   /ip dns print
   ```
- **“insufficient space …”** → звільніть місце у **Files** (видаліть зайве), повторіть запуск.
- **На CAP помилка “failed to download … .npk, no such file”** → на CAP встановлений додатковий пакет (наприклад, `calea`). Додайте відповідний `.npk` для його архітектури (`-arm` або `-arm64`) у **Files** контролера та повторіть.