# CAPsMAN Bulk Upgrade (ac + ax, RouterOS ≥ 7.16) — README (UA)

Цей скрипт оновлює **контролер** MikroTik (CAPsMAN) та **CAP-пристрої** до **останньої** версії RouterOS на **поточному** каналі оновлень однією командою. Підтримує змішане оточення legacy `/caps-man` і новий `/interface wifi capsman`.

Скрипт **автоматично визначає** доступні утиліти, **детектує архітектуру кожного CAP-а** (ARM/ARM64), завантажує **тільки потрібні пакети** для наявних архітектур та показує зручне **UPGRADE SUMMARY** з командами в кінці.

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
- Перевіряє версію **контролера** і **кожного CAP-а** з **автоматичним визначенням архітектури** (ARM/ARM64).
- Якщо **всі на останній версії** — **нічого не завантажує** і завершує роботу.
- Якщо потрібне оновлення:
  - Перевіряє **вільний простір** на контролері; якщо мало — зупиняється з чітким повідомленням.
  - **Визначає архітектуру** кожного CAP-а по назві плати/моделі (board/model)
  - Завантажує **рівно ті пакети**, що потрібні для **детектованих** архітектур:
    - База: `routeros-<ver>-arm.npk`, `routeros-<ver>-arm64.npk`
    - Драйвери Wi-Fi: `wifi-qcom-ac-<ver>-arm.npk`, `wireless-<ver>-arm.npk`, `wifi-qcom-<ver>-arm64.npk`
    - Додатково: `calea-<ver>-arm(.npk)` і `-arm64` (для CAP-ів з CALEA пакетом)
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

## ⚠️ Обмеження

- **Не підтримує MIPSBE/MIPSEL архітектури** - скрипт розроблений для сучасних ARM/ARM64 пристроїв.
- Для старих MIPS контролерів (RB750, RB951, etc.) використовуйте стандартні команди оновлення RouterOS.
- Скрипт оптимізований для **продуктивних розгортань** з ARM/ARM64 контролерами та CAP-ами.

---

## ⚙️ Налаштування (на початку скрипта)

- `:local minFreePerPkgBytes 14000000` — оцінка потрібного місця (≈14 МіБ на пакет: база RouterOS=12МБ + буфер).

- `:local cleanupDelay "120s"` — час на завантаження пакетів CAP-ами перед видаленням `.npk`.

## 🔍 Детекція архітектури

Скрипт автоматично визначає архітектуру кожного CAP-а по назві плати/моделі:

**ARM64 пристрої:**
- Плати з "ax", "AX" в назві (наприклад: hAP-ax3, cAP-ax)
- RB5009, RB4011, RB3011

**ARM пристрої:**  
- hAP серія (крім ax): hAP-ac, hAP-ac², etc.
- cAP серія (крім ax): cAP-ac
- wAP серія: wAP, RBwAP
- Всі інші legacy пристрої

**За замовчуванням:**
- Legacy CAPsMAN (`/caps-man`) → ARM
- WiFi CAPsMAN (`/interface wifi capsman`) → ARM64

## 📋 Поведінка скрипта

- **Детекція архітектур**: Скрипт визначає архітектуру (ARM/ARM64) кожного CAP-а по назві плати/моделі.
- **CAP-и** оновлюються **автоматично** (безпечно, самі керують перезавантаженням).
- **Контролер** завжди вимагає **ручного перезавантаження** для безпеки.
- В кінці скрипт показує **UPGRADE SUMMARY** з усіма потрібними командами.
- Для оновлення контролера просто запустіть: `/system reboot` (RouterOS автоматично встановить завантажений .npk файл).

## 📺 Приклад виводу

```
cap-bulk-upgrade: Available utilities - legacy caps-man: false, wifi capsman: true
cap-bulk-upgrade: latest=7.19.4  controller=7.17.2
cap-bulk-upgrade: discovered wifi CAPs: 2
cap-bulk-upgrade: CAP (wifi) Office-AX [hAP-ax3/arm64] needs 7.17.2 -> 7.19.4
cap-bulk-upgrade: CAP (wifi) Lobby-AC [cAP-ac/arm] already 7.19.4, skipping
fetch routeros-7.19.4-arm64.npk
fetch wifi-qcom-7.19.4-arm64.npk
[...завантаження...]
cap-bulk-upgrade: controller needs upgrade (7.17.2 -> 7.19.4), package downloaded
cap-bulk-upgrade: upgrading wifi CAPs: 0
cap-bulk-upgrade: finished

=================================================================
UPGRADE SUMMARY
=================================================================

Controller: 7.17.2 -> 7.19.4 (READY - manual reboot required)

To complete controller upgrade, copy and run:
/system reboot

RouterOS will automatically install: routeros-7.19.4-arm64.npk

NOTE: Controller reboot does NOT affect CAP operations.

CAPs: UPGRADING (automatic, will complete shortly)

=================================================================
```


## 🧰 Усунення несправностей

- **"cannot detect latest-version"** → перевірте DNS/Інтернет на контролері:
   ```rsc
   /ping 8.8.8.8 count=3
   /ip dns print
   ```
- **"insufficient space …"** → звільніть місце у **Files** (видаліть зайве), повторіть запуск.
- **На CAP помилка "failed to download … .npk, no such file"** → на CAP встановлений додатковий пакет (наприклад, `calea`). Додайте відповідний `.npk` для його архітектури (`-arm` або `-arm64`) у **Files** контролера та повторіть.
- **Неправильна детекція архітектури** → скрипт визначає архітектуру по назві плати. Перевірте логи для `[board/arch]` інформації.
- **Немає CAP-ів** → скрипт покаже "No CAPs detected" замість "UP-TO-DATE" (нормально для одиноких пристроїв).