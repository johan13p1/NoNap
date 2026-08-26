# NoNap

Hält den Mac wach — auch bei zugeklapptem Deckel, für eine selbst gewählte Dauer.

Ein Klick auf das Symbol in der Menüleiste, eine Dauer wählen, fertig. Läuft die
Zeit ab, gibt NoNap den Schlaf von selbst wieder frei.

## Warum zwei Teile?

Das ist der Kern der Sache und der Grund, warum diese App so gebaut ist, wie sie
gebaut ist.

Der übliche Weg, einen Mac wachzuhalten — `caffeinate` oder eine
`IOPMAssertion` — verhindert nur den **Leerlauf-Schlaf**. Klappt man den Deckel
zu, schläft der Mac trotzdem ein. Das lässt sich ausschließlich über die
Power-Management-Einstellung `SleepDisabled` abschalten, und die ist
root-geschützt.

Deshalb besteht NoNap aus:

| Teil | Rechte | Aufgabe |
|---|---|---|
| **NoNap.app** | normale Benutzerrechte | Menüleiste, Einstellungen, Anzeige |
| **NoNapHelper** | root (LaunchDaemon) | setzt `SleepDisabled`, überwacht die Frist |

Der Helfer ist bewusst winzig und tut nichts anderes. Sein gesamter Code liegt in
`NoNapHelper/` — sieben Dateien, die man an einem Nachmittag durchlesen kann.

Statt undokumentierter IOKit-Aufrufe verwendet er `/usr/bin/pmset`. Das Symbol
`_IOPMSetSystemPowerSetting` ist zwar in IOKit vorhanden, aber in keinem
öffentlichen Header deklariert — in einem Prozess mit Systemrechten ist ein
undokumentiertes Symbol das schlechtere Geschäft. Jeder Schritt lässt sich im
Terminal nachprüfen:

```bash
pmset -g | grep SleepDisabled
```

## Einrichten

1. **App an einen festen Ort legen** — am besten `/Applications`.

   Wichtig: Erst verschieben, dann den Hintergrunddienst einrichten. Die
   Registrierung merkt sich den Pfad der App. Liegt sie noch im
   Xcode-Build-Ordner und der wird geleert, zeigt der Dienst ins Leere.

2. App starten. Das Symbol erscheint rechts in der Menüleiste.

3. Panel öffnen → **Hintergrunddienst einrichten**. macOS fragt einmalig nach
   dem Administrator-Passwort.

Der Dienst taucht danach unter *Systemeinstellungen › Allgemein ›
Anmeldeobjekte* auf und kann dort jederzeit abgeschaltet werden.

## Einstellungen

**Allgemein**
- NoNap beim Anmelden starten
- Verbleibende Zeit in der Menüleiste anzeigen
- Voreingestellte Dauer
- Display ebenfalls wachhalten (wirkt nur am offenen Gerät)
- Mitteilung, wenn eine Session von selbst endet

**Schutz** — die Notbremse
- Session bei niedrigem Akku beenden (Schwelle einstellbar, Vorgabe 20 %)
- Session beenden, wenn das Netzteil abgezogen wird

Diese Grenzen überwacht der Hintergrunddienst selbst. Sie greifen auch dann,
wenn die App abgestürzt oder beendet wurde.

**Hintergrunddienst** — Zustand einsehen, einrichten, entfernen

## Was passiert, wenn etwas schiefgeht

Ein Mac, der nicht mehr einschläft und bei dem niemand mehr weiß, warum, wäre
das schlechteste denkbare Ergebnis. Dagegen sind mehrere Sicherungen eingebaut:

- **App stürzt ab** → Die Session läuft bis zu ihrer Frist weiter und endet dann
  regulär. Der Helfer, nicht die App, führt die Uhr.
- **Helfer stürzt ab** → launchd startet ihn neu, er liest die gespeicherte
  Session und stellt den richtigen Zustand wieder her.
- **Mac wird neu gestartet** → `SleepDisabled` überlebt einen Neustart. Der
  Helfer startet deshalb beim Systemstart mit, erkennt den Neustart an der
  Boot-Zeit, verwirft die Session und gibt den Schlaf frei.
- **`SleepDisabled` wird von außen verstellt** → Ein Heartbeat prüft das jede
  Minute und stellt den erwarteten Zustand wieder her.
- **Helfer wird beendet** (`SIGTERM`, Deinstallation) → gibt den Schlaf vorher frei.
- **App wird beendet, während eine Session läuft** → NoNap fragt nach, ob die
  Session mit beendet werden soll.

## Sicherheit

Der Helfer läuft als root und nimmt XPC-Verbindungen entgegen. Ein Mach-Service,
den jedes beliebige Programm ansprechen darf, wäre eine Rechteausweitung.
Deshalb prüfen **beide Seiten** die Signatur der Gegenstelle über
`setConnectionCodeSigningRequirement` bzw. `setCodeSigningRequirement`:

```
identifier "com.johan.NoNap" and anchor apple generic
    and certificate leaf[subject.OU] = "FZL5999DHB"
```

Verbindungen, die das nicht erfüllen, weist XPC ab, bevor überhaupt Code von
NoNap läuft. Die Team-ID steht in `Shared/NoNapShared.swift` und muss zu der
Signierungsidentität passen, mit der gebaut wird.

## Aufbau

```
NoNap/          App: Menüleiste, Einstellungen, XPC-Client
NoNapHelper/    Privilegierter Daemon (root)
Shared/         XPC-Protokoll und Bezeichner, von beiden Targets genutzt
Resources/      LaunchDaemon-Property-List
```

Der Helfer wird beim Bauen nach `NoNap.app/Contents/MacOS/` kopiert, die
Property-List nach `NoNap.app/Contents/Library/LaunchDaemons/`.

## Ein Hinweis zur Wärme

Ein zugeklappter Mac unter Last kann keine Wärme abführen. Für lange Sessions
mit rechenintensiven Aufgaben gilt: nicht in Tasche oder Rucksack. Die
Akku-Notbremse hilft gegen leere Akkus, nicht gegen Hitzestau.

## Bauen

```bash
xcodebuild -project NoNap.xcodeproj -scheme NoNap -configuration Release build
```

Voraussetzungen: macOS 14 oder neuer, eine Signierungsidentität mit der in
`NoNapShared.swift` hinterlegten Team-ID.
