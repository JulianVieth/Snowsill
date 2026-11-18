# Snowsill – Schnee für den macOS-Desktop

Menüleisten-App für macOS, die Schnee über den Bildschirm fallen lässt. Der Schnee bleibt auf den Oberkanten der Fenster und am unteren Bildschirmrand liegen, rutscht ab, wenn ein Fenster bewegt wird, und schmilzt langsam weg. Privates Spaßprojekt: keine App-Store-Distribution, keine Sandbox.

## Tech-Stack

- Swift (Language Mode 5), macOS 14+, Apple Silicon
- Swift Package (kein Xcode-Projekt), keine Third-Party-Dependencies
- AppKit für das Overlay-Fenster, Metal (`MTKView`, instanziertes Rendering) fürs Rendering, SwiftUI `MenuBarExtra` für die Einstellungen
- `CGWindowListCopyWindowInfo` für Fensterpositionen
- Tests mit `swift-testing` (oder XCTest), nur für die reine Logik

## Befehle

```sh
swift build                 # nach JEDER Änderung ausführen, Fehler sofort beheben
swift test                  # Logik-Tests
swift run Snowsill          # starten (Beenden über das Menüleisten-Icon)
./scripts/bundle.sh         # baut Snowsill.app (nötig für Launch at Login)
SNOWSILL_SNAPSHOT=drag swift run Snowsill   # Snapshot-Modus, Szenarien siehe unten
SNOWSILL_LOGIN_ITEM=status Snowsill.app/Contents/MacOS/Snowsill   # Login-Objekt prüfen (status|on|off), nur im Bundle
SNOWSILL_SELFTEST=mouse swift run Snowsill   # Mauspfad live prüfen (Hover/Klick-Durchlass, Schneemann bauen), ohne echte Maus-Events
```

Szenarien: drag, close, ground, overlap, plow, snowman (Maus per Skript), icicles, secondary (Zweitbildschirm), widgets, wind, icons, carry (Schneemann auf ein Fenster tragen).

Snapshot-Modus (`Sources/Snowsill/Snapshot/`): spielt ein Szenario mit simulierten Fenstern auf virtueller Uhr ab (fester Seed, schneller als Echtzeit), rendert offscreen und schreibt nach `snapshots/<szenario>/`: `sheet.png` (Übersicht), `tNNN.NN.png` (ganzer Bildschirm), `detail_*.png` (2×-Ausschnitt) und `stats.txt` (Flocken, Pulver, Höhen je Oberfläche). Neue Features bekommen ein eigenes Szenario.

## Architektur

```
Sources/Snowsill/              (executableTarget, AppKit/Metal/SwiftUI)
  App/          SnowsillApp.swift (MenuBarExtra, Activation Policy .accessory), SnowSettings.swift (UserDefaults)
  Overlay/      OverlayWindow.swift (nicht aktivierendes Panel + View mit Maus), OverlayController.swift (ein Overlay pro Bildschirm, Pause, Maus)
  Windows/      WindowTracker.swift (CGWindowList-Polling)
  Rendering/    SnowRenderer.swift (MTKViewDelegate, Frame-Loop), Shaders.swift (MSL-Quelltext, Sprite-Formen)
  Snapshot/     SnapshotRunner.swift, SnapshotScenario.swift
Sources/SnowsillCore/          (Library, nur Foundation/CoreGraphics – testbar)
  Simulation/   Flake.swift, Surface.swift (Heightmap), SnowSimulation.swift, Wind.swift, Occlusion.swift,
                Plow.swift, Snowballs.swift, Icicles.swift
  Rendering/    Sprites.swift (Instanzdaten, Flocken packen), SceneSprites.swift (Schaufler, Kugeln, Eiszapfen),
                SurfaceMesh.swift (GPU-Daten packen, ohne Metal-Import)
  Windows/      WindowFilter.swift (Fensterliste, Widgets, Klick-Blocker, aktives Fenster; reine Logik)
  Util/         Coordinates.swift, Noise.swift
Tests/SnowsillTests/           (swift-testing, testet SnowsillCore)
```

Simulation (reines Swift, kein AppKit/Metal-Import) und Rendering bleiben strikt getrennt. Die Simulation bekommt Oberflächen und Bildschirme als Werte rein und gibt Flocken und Heightmaps raus. Dadurch ist sie testbar.

## Kernkonzepte

### Overlay-Fenster
- Ein randloses `NSWindow` pro `NSScreen`, `frame = screen.frame`
- `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`, standardmäßig `ignoresMouseEvents = true`
- Interaktion (Schneekugeln, siehe unten): Die Mausposition wird gepollt. Nur wenn der Cursor über greifbarem Schnee am Boden, einer Kugel oder einem Schneemann steht, wird `ignoresMouseEvents = false` gesetzt und der Cursor zur offenen Hand. Sonst gehen alle Klicks durch. Klicks auf Fenster dürfen nie abgefangen werden.
- `level = .floating` (3): über normalen Fenstern, unter Menüleiste (24), Menüs, Alerts (8), Spotlight und Mitteilungen. Nicht `.statusBar` (25), das liegt über Menüleiste und Alerts. Das Dock (20) liegt über dem Schnee.
- `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`
- „Schnee im Vollbildmodus“ aus: Das Overlay des Bildschirms wird ausgeblendet und pausiert. `.fullScreenAuxiliary` wegzulassen reicht nicht (live geprüft 2026-11-18): Panels einer Agent-App (`LSUIElement`) erscheinen trotzdem über Vollbild-Apps. Erkannt wird Vollbild in der Fensterliste (`WindowFilter.fullScreenCandidates`): ein Fenster auf Ebene 0 deckt genau den Bildschirm ab und auf ihm liegt keine Menüleiste (Ebene `mainMenuWindow`); ein maximiertes Fenster lässt die Menüleiste stehen. Nur dann bestätigt eine zweite Abfrage ohne `.excludeDesktopElements`, dass dort kein Schreibtisch-Fenster liegt (schließt automatisch ausgeblendete Menüleiste + Dock aus).
- `MTKView` mit `layer.isOpaque = false`, `clearColor` mit Alpha 0, Blending mit vormultipliziertem Alpha. Shader werden zur Laufzeit mit `makeLibrary(source:)` kompiliert, weil die Command Line Tools keinen Offline-Metal-Compiler haben.
- Bei `NSApplication.didChangeScreenParametersNotification` die Overlays neu aufbauen

### Koordinatensysteme (häufigste Fehlerquelle!)
- `CGWindowList` liefert globale Koordinaten mit Ursprung **oben links** des Hauptbildschirms, y wächst nach unten
- AppKit (`NSScreen.frame`, `NSWindow`) nutzt Ursprung **unten links**, y wächst nach oben
- Hauptbildschirm ist `NSScreen.screens[0]`, **nicht** `NSScreen.main` (das ist der Bildschirm mit dem Key-Window)
- Umrechnung: `cgY = mainScreenHeight - (appKitY + height)`
- **Die Simulation rechnet komplett in CG-Koordinaten.** Umgerechnet wird nur beim Rendern in die lokale Szene des jeweiligen Bildschirms. Alles davon steckt in `Coordinates.swift` und ist getestet.

### Fenster erkennen
- `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)` auf einer Background-Queue abfragen: 12 Hz in Ruhe, nach jeder Änderung 0,5 s lang 60 Hz (eine Abfrage kostet ca. 0,3 ms), damit der Schnee beim Ziehen am Fenster klebt. Während schneller Phase wird jede Abfrage geliefert, auch unveränderte, damit ein Stillstand sofort erkannt wird. Der Renderer zeichnet bewegte Fensterkanten um Geschwindigkeit × Latenz vorausberechnet; dazu `maximumDrawableCount = 2`. Minimieren ist erst erkennbar, wenn das Fenster nach der Animation aus der Liste verschwindet.
- Nur `kCGWindowLayer == 0` verwenden. Herausfiltern: eigene PID, `kCGWindowAlpha == 0` und Fenster unter 80×40 pt
- Nur `kCGWindowBounds`, `kCGWindowNumber`, `kCGWindowOwnerPID` und `kCGWindowLayer` lesen. **`kCGWindowName` nicht verwenden**, sonst verlangt macOS die Bildschirmaufnahme-Berechtigung.
- Fenster über `kCGWindowNumber` identifizieren. Pro Poll diffen: neu, bewegt/skaliert oder verschwunden.
- Die Liste ist von vorne nach hinten sortiert. Daraus berechnet `Occlusion.swift` die sichtbaren Segmente jeder Oberkante (abzüglich der Rechtecke der Fenster davor).

### Liegender Schnee (Surface)
- Jede Oberfläche (sichtbares Segment einer Fensteroberkante oder der Bildschirmboden) hat eine Heightmap mit Spalten à 2 pt
- Trifft eine Flocke auf eine Oberfläche, wird ihr Volumen auf die Spalte addiert
- Schüttwinkel: Ist eine Spalte mehr als ca. 1,5× Spaltenbreite höher als ihr Nachbar, rutscht Schnee zur Seite (Sandpile-Regel). An den Rändern von Fenstern fällt er als Pulver herunter, am Boden sind die Ränder Wände.
- Maximale Höhe: ca. 14 pt auf Fenstern, ca. 50 pt am Boden
- Schmelzen: langsamer, konstanter Abbau. Etwas schneller, wenn lange kein neuer Schnee kommt.
- Wird ein Fenster bewegt, wandert sein Schnee als zusammenhängende Masse mit (`Surface.relocate`, spaltengenau, ohne Verlust). Beim Skalieren bleibt er an seiner absoluten Position.
- Herunter fällt Schnee nur, wo er über eine Kante gerät: bei schnellem seitlichen Ziehen (Trägheit ab ca. 900 pt/s, er rutscht zur hinteren Kante), beim Verkleinern, an der Bildschirmkante und beim Schließen oder Minimieren (dann die ganze Schicht)
- Minimieren: Während der Animation meldet `CGWindowList` schrumpfende Rahmen. Erkannt wird es daran, dass Ober- und Unterkante gemeinsam sinken, während sich die Größe ändert; von Hand gibt es das nicht (Verschieben behält die Größe, Größe-Ändern lässt oben oder unten stehen). Genie streckt das Fenster vorher seitwärts, dabei bleibt der Schnee liegen. Aufzeichnung als Test in `WindowSnowTests.genie`. Dann fällt der Schnee sofort von seinem Platz, und das Fenster trägt keinen, bis es weg ist oder 1 s still steht.
- Es läuft immer nur eine Instanz: Zwei würden doppelt schneien und sich gegenseitig die Klicks blockieren.
- Herabfallender Schnee sind **Klumpen plus etwas Pulver** (wie im snowcat-Referenzvideo): grobe, unregelmäßige Brocken, die beim Aufprall zu Pulver zerstäuben, dazu feines Pulver (1–2 pt), langsamer, stärkeres Pendeln. Jedes Partikel trägt sein Schneevolumen und gibt es beim Landen wieder ab, die Menge bleibt erhalten.
- Gerendert wird pro Oberfläche ein Triangle-Strip in Metal (weiß, leicht bläulicher Schatten). Die Vertices nur neu bauen, wenn sich die Heightmap geändert hat, höchstens mit 20 Hz.
- Look (Referenzvideos `*.mp4` im Repo-Root): Fensterkappen dick, bucklig und wolkig mit weichem Schatten statt einer flachen Schicht. Die Bodenschicht hat eine ausgefranste, unregelmäßige Oberkante. Die Unregelmäßigkeit ist rein visuell (deterministisches Rauschen über x), die Heightmap bleibt die Wahrheit.
- Eiszapfen an den Fensterunterkanten: wachsen langsam, wenn auf dem Fenster länger Schnee liegt, und brechen ab bzw. verschwinden, wenn das Fenster schnell bewegt oder geschlossen wird.

### Schneekugeln und Schneemänner
- Über Schnee mit genug Höhe (Boden, Fensterkappe, Widget, Icon) wird der Cursor zur Hand. Ziehen rollt eine Kugel auf der Fläche darunter: Sie wächst mit der zurückgelegten Strecke und nimmt das Volumen aus den überrollten Heightmap-Spalten auf (Volumen bleibt erhalten, ohne Schnee wächst sie nicht). Die Kappe liegt über der Fensteroberkante, Klicks ins Fenster bleiben unberührt.
- Doppelklick auf eine Kugel oder einen Schneemann lässt ihn zu Klumpen und Pulver zerplatzen (Volumen bleibt erhalten).
- Loslassen: Die Kugel fällt auf die Oberfläche darunter (Boden oder Fensteroberkante) und bleibt liegen. Kugeln lassen sich erneut greifen und verschieben. Wer die unterste Kugel eines Stapels greift, trägt den ganzen Stapel bzw. Schneemann (er rollt dabei nicht und wächst nicht); wer eine obere greift, nimmt die oberste ab.
- Wird eine kleinere Kugel auf eine größere gesetzt, wird sie gestapelt. Bei drei Kugeln ist der Schneemann fertig und bekommt Kohleaugen, Karottennase, Knopfreihe, Zweigarme und Hut.
- Auf Fenstern wandern Kugeln und Schneemänner mit dem Fenster mit. Wird das Fenster geschlossen oder verschwindet die Fläche unter ihnen, fallen sie herunter und zerplatzen zu Klumpen und Pulver.
- Logik (Kugelwachstum, Stapeln, Auflageflächen) in `SnowsillCore`, getestet. Gezeichnet prozedural im Shader (Kreise mit Schattierung), keine Bilddateien.

### Schneeschaufler
- Ein kleines Räumfahrzeug fährt regelmäßig am Bildschirmboden von einer Seite zur anderen, damit die Bodenschicht nicht zu einem gleichmäßigen Block wird. Es kommt, wenn die mittlere Bodenhöhe einen Schwellwert überschreitet, frühestens alle paar Minuten. Ist der Boden zu 80 % voll, schon nach 30 s Pause (bei Schneesturm ist er in gut einer Minute voll).
- Vor der Schaufel sammelt sich Schnee als Wall, dahinter bleibt eine dünne, unregelmäßige Restschicht. Der Wall ist Teil der Boden-Heightmap direkt vor der Schaufel: ein Wulst bis 16 pt über dem unberührten Schnee davor, der über 60 pt in ihn ausläuft (eine Masse, auch in tiefem Schnee sichtbar); über die Krone kippen immer wieder kleine Klumpen nach vorn, schneller als der Schaufler, damit sie nicht hinter ihm landen (nicht in der Nähe von Gebautem); die Schaufel ist eine Wand für die Sandpile-Regel und für die Glättung beim Zeichnen, damit nichts nach hinten verschmiert. Was nicht in den Wall passt, schiebt er zur Seite aus dem Bild (`Plow.pushedAside`), wie ein echter Räumer an den Straßenrand; am Bildschirmrand fliegt es als Klumpen hinaus. Bewusste Abweichung von der Volumenerhaltung (2026-11-17, nach Julians Abnahme: ein voll erhaltener Wall wurde zum Block und zu einer zweiten Masse).
- Kugeln und Schneemänner am Boden hält es nicht auf (2026-11-18, Julians Wunsch; vorher hielt es davor an, dann blieb der Boden bei Schneesturm voll): Es fährt hinter ihnen durch (wird vor ihnen gezeichnet, also dahinter) und räumt auch den Schnee unter ihnen weg. Unter Gebautem baut sich kein Wall auf, damit es nicht erst angehoben wird. Sinkt der Boden unter einem Stapel um mehr als 2 pt, fällt er mit Schwerkraft herunter und bleibt ganz.
- Die Schaufel ist mindestens so hoch wie der Schnee direkt davor plus 4 pt (`Plow.bladeTop`, wächst schnell, schrumpft langsam), mindestens 18 pt. Seitenansicht eines echten Räumschilds: gebogenes Streichblech (Kreisbogen, nach vorn offen, oben nach vorn eingerollt), Stahl-Schürfkante unten, Seitenplatte als Sichel hinter der Wölbung (verdeckt die gerade Schneekante), Schubrahmen und ab 26 pt ein Hubzylinder. Die Wölbung liegt im Schnee, Fuß und Oberkante ragen in den Wall.
- Das Dock liegt über dem Overlay, der Schaufler ist also hinter dem Dock teilweise verdeckt. Das ist in Ordnung.

### Schnee auf Schreibtisch-Icons und Widgets
- Gewünscht: Schnee bleibt auch auf Schreibtisch-Icons und Widgets liegen.
- Widgets (umgesetzt): Jedes Widget ist ein eigenes Fenster von `com.apple.notificationcenterui` auf Layer `kCGDesktopIconWindowLevel + 2`, auch mit `.excludeDesktopElements` in der Liste. Die Fenster sind rundum 8 pt größer als die sichtbare Kachel (`WindowFilter.widgetPadding`). Sie liegen hinter allen normalen Fenstern, tragen Schnee, aber keine Eiszapfen.
- Desktop-Icons (umgesetzt, freigegeben am 2026-11-17): Die Icons sind ein einziges Finder-Fenster ohne Einzelpositionen, deshalb liest `DesktopIconReader` die Rahmen über die Accessibility-API (Finder → AXScrollArea → AXImage), alle 2 s im Hintergrund. Standardmäßig aus; beim Einschalten im Menü fragt macOS nach „Bedienungshilfen“. Ohne Freigabe liefert er nichts. Der AX-Rahmen ist größer als die Grafik (bei 96 pt: oben ca. 7 pt, seitlich je ca. 15 pt Luft), `DesktopIcons.artwork` rechnet das heraus. Live geprüft am 2026-11-17 („Macintosh HD“: Rahmen 1584/58/96×96). Icons liegen hinter Fenstern und Widgets, flache Kappe (`iconMaxHeight`), keine Eiszapfen, Klicks auf Icons gehen immer durch. Prüfen: `open -W --env SNOWSILL_ICONS=list --stdout /tmp/icons.txt Snowsill.app && cat /tmp/icons.txt` bzw. im Debug-Modus die roten Linien.

### Fallende Flocken
- Struct mit `position`, `velocity`, `radius`, `swayPhase`, `opacity`. Pool mit fester Maximalgröße (Standard 800, maximal 2500), dazu 2200 Plätze für Pulver, damit auch ein volles Fenster komplett zerstäuben kann, ohne den Schneefall zu unterbrechen
- Bewegung: Fallgeschwindigkeit abhängig von der Größe, sinusförmiges Pendeln, dazu der globale Wind
- Wind: ruhige Grundbrise plus zufällige Böen (geglättetes Rauschen). Gelegentlich kurze „Flurries“ mit vielen Flocken.
- Kollision: pro Frame prüfen, ob die Flocke eine Oberkante innerhalb ihres x-Bereichs von oben gekreuzt hat. Bei ein paar Dutzend Oberflächen reicht das naiv aus.
- Rendering: alle aktiven Partikel und Szenenobjekte werden pro Frame in einen vorallokierten `MTLBuffer` gepackt (`FlakeSprites.pack`, `SceneSprites.write`, getestet) und mit einem einzigen instanzierten Draw-Call gezeichnet. Die Scheibe entsteht prozedural im Fragment-Shader. Nicht SpriteKit: 800 `SKSpriteNode`s kosteten allein durch die Property-Setter ca. 10 % CPU.

### Menüleiste und Einstellungen
- `MenuBarExtra` mit Schneeflocken-SF-Symbol. Optionen: An/Aus, Intensität (leicht / mittel / Schneesturm), Flockengröße, Wind, Modus „nur aktives Fenster“ oder „alle Fenster“, Schnee am Boden an/aus, Schaufler, Schneemänner, Eiszapfen, Widgets, Schreibtisch-Icons, Schnee im Vollbildmodus, „Schnee abschütteln“ (Reset), Launch at Login, Beenden
- Persistenz über `@AppStorage` / `UserDefaults`
- Launch at Login über `SMAppService.mainApp` (funktioniert nur im `.app`-Bundle)

## Performance-Ziele

- Unter 5 % CPU bei mittlerer Intensität auf einem M-Chip
- Adaptive Bildrate: 60 fps, solange ein Fenster bewegt wird oder die Maus über Schnee ist bzw. eine Kugel zieht, sonst 30 fps; im Akkubetrieb und Stromsparmodus immer 30. Grund: Jeder Frame kostet fest ca. 1 ms CPU pro Bildschirm (Drawable, Submit), unabhängig vom Inhalt. Gemessen: ca. 5,7 % pro Bildschirm bei durchgehend 60 fps, ca. 2,8 % adaptiv.
- Pausieren bei Bildschirmsperre, Display-Sleep und Bildschirmschoner (`NSWorkspace`- bzw. `DistributedNotificationCenter`-Notifications)
- Keine Allokationen im Frame-Loop: Flocken kommen aus dem Pool, Instanz-Puffer sind dreifach vorallokiert

## Meilensteine

1. Transparentes Overlay auf dem Hauptbildschirm, Flocken fallen durch und verschwinden unten
2. Schneeverwehung am Bildschirmboden (Heightmap und Rendering)
3. Schnee bleibt auf dem **aktiven Fenster** liegen und fällt ab, wenn es bewegt wird
4. Look wie in den Referenzvideos: bucklige Fensterkappe, ausgefranster Bodenrand, Klumpen statt nur Pulver beim Herunterfallen
5. Alle sichtbaren Fenster inklusive Verdeckung
6. Schneeschaufler am Boden
7. Schneekugeln rollen und Schneemänner bauen (inkl. Klick-Durchlass-Logik)
8. Eiszapfen an Fensterunterkanten
9. Mehrere Bildschirme
10. Schnee auf Schreibtisch-Icons und Widgets (erst Machbarkeit prüfen)
11. Menüleisten-Einstellungen und Persistenz (inkl. Schaufler und Schneemänner an/aus)
12. Wind, Böen und Schmelzen
13. `bundle.sh`, App-Icon und Launch at Login

Immer nur einen Meilenstein auf einmal umsetzen. Danach bauen, testen, committen und mich bitten, es visuell zu prüfen.

## Arbeitsregeln für Claude

- Visuelle Änderungen zuerst selbst prüfen: Snapshot-Szenario laufen lassen und die Bilder ansehen; mit Bildschirmaufnahme-Berechtigung zusätzlich `screencapture -x` auf dem echten Bildschirm. Danach sag mir konkret, worauf ich noch achten soll (v. a. Ruckeln und Latenz, die Snapshots nicht zeigen), und warte auf mein Feedback.
- Für Debugging einen versteckten Debug-Modus einbauen (Umgebungsvariable `SNOWSILL_DEBUG=1`): Oberflächen als rote Linien zeichnen, FPS und Flockenzahl anzeigen
- Für Koordinatenumrechnung, Verdeckung, Heightmap und Sandpile-Regel immer Tests schreiben, bevor ein Bug dort „gefixt“ wird
- Keine neuen Dependencies ohne Rückfrage
- Kleine Commits mit aussagekräftigen Messages auf Deutsch
- Code und Bezeichner auf Englisch, Kommentare nur, wo das *Warum* nicht offensichtlich ist
- Swift-Concurrency: UI und Rendering laufen auf `@MainActor`, das Fenster-Polling im Hintergrund. Ergebnisse als unveränderliche Snapshots an den Main Actor übergeben.
