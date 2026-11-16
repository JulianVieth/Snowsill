# SnowPile – Schnee für den macOS-Desktop

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
swift run SnowPile          # starten (Beenden über das Menüleisten-Icon)
./scripts/bundle.sh         # baut SnowPile.app (nötig für Launch at Login)
```

## Architektur

```
Sources/SnowPile/              (executableTarget, AppKit/Metal/SwiftUI)
  App/          SnowPileApp.swift (MenuBarExtra, Activation Policy .accessory), Settings.swift
  Overlay/      OverlayWindow.swift (ein Fenster pro Bildschirm), OverlayController.swift
  Windows/      WindowTracker.swift (CGWindowList-Polling)
  Rendering/    SnowRenderer.swift (MTKViewDelegate, Frame-Loop), Shaders.swift (MSL-Quelltext)
Sources/SnowPileCore/          (Library, nur Foundation/CoreGraphics – testbar)
  Simulation/   Flake.swift, Surface.swift (Heightmap), SnowSimulation.swift, Wind.swift, Occlusion.swift
  Rendering/    FlakeInstances.swift, SurfaceMesh.swift (GPU-Daten packen, ohne Metal-Import)
  Windows/      WindowFilter.swift (Fensterliste filtern, aktives Fenster; reine Logik)
  Util/         Coordinates.swift
Tests/SnowPileTests/           (swift-testing, testet SnowPileCore)
```

Simulation (reines Swift, kein AppKit/Metal-Import) und Rendering bleiben strikt getrennt. Die Simulation bekommt Oberflächen und Bildschirme als Werte rein und gibt Flocken und Heightmaps raus. Dadurch ist sie testbar.

## Kernkonzepte

### Overlay-Fenster
- Ein randloses `NSWindow` pro `NSScreen`, `frame = screen.frame`
- `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`, `ignoresMouseEvents = true`
- `level = .floating` (3): über normalen Fenstern, unter Menüleiste (24), Menüs, Alerts (8), Spotlight und Mitteilungen. Nicht `.statusBar` (25), das liegt über Menüleiste und Alerts. Das Dock (20) liegt über dem Schnee.
- `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`
- `MTKView` mit `layer.isOpaque = false`, `clearColor` mit Alpha 0, Blending mit vormultipliziertem Alpha. Shader werden zur Laufzeit mit `makeLibrary(source:)` kompiliert, weil die Command Line Tools keinen Offline-Metal-Compiler haben.
- Bei `NSApplication.didChangeScreenParametersNotification` die Overlays neu aufbauen

### Koordinatensysteme (häufigste Fehlerquelle!)
- `CGWindowList` liefert globale Koordinaten mit Ursprung **oben links** des Hauptbildschirms, y wächst nach unten
- AppKit (`NSScreen.frame`, `NSWindow`) nutzt Ursprung **unten links**, y wächst nach oben
- Hauptbildschirm ist `NSScreen.screens[0]`, **nicht** `NSScreen.main` (das ist der Bildschirm mit dem Key-Window)
- Umrechnung: `cgY = mainScreenHeight - (appKitY + height)`
- **Die Simulation rechnet komplett in CG-Koordinaten.** Umgerechnet wird nur beim Rendern in die lokale Szene des jeweiligen Bildschirms. Alles davon steckt in `Coordinates.swift` und ist getestet.

### Fenster erkennen
- `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)` mit 10–15 Hz auf einer Background-Queue abfragen
- Nur `kCGWindowLayer == 0` verwenden. Herausfiltern: eigene PID, `kCGWindowAlpha == 0` und Fenster unter 80×40 pt
- Nur `kCGWindowBounds`, `kCGWindowNumber`, `kCGWindowOwnerPID` und `kCGWindowLayer` lesen. **`kCGWindowName` nicht verwenden**, sonst verlangt macOS die Bildschirmaufnahme-Berechtigung.
- Fenster über `kCGWindowNumber` identifizieren. Pro Poll diffen: neu, bewegt/skaliert oder verschwunden.
- Die Liste ist von vorne nach hinten sortiert. Daraus berechnet `Occlusion.swift` die sichtbaren Segmente jeder Oberkante (abzüglich der Rechtecke der Fenster davor).

### Liegender Schnee (Surface)
- Jede Oberfläche (sichtbares Segment einer Fensteroberkante oder der Bildschirmboden) hat eine Heightmap mit Spalten à 2 pt
- Trifft eine Flocke auf eine Oberfläche, wird ihr Volumen auf die Spalte addiert
- Schüttwinkel: Ist eine Spalte mehr als ca. 1,5× Spaltenbreite höher als ihr Nachbar, rutscht Schnee zur Seite (Sandpile-Regel). An den Rändern fällt er herunter, also wird er wieder zur Flocke.
- Maximale Höhe: ca. 14 pt auf Fenstern, ca. 50 pt am Boden
- Schmelzen: langsamer, konstanter Abbau. Etwas schneller, wenn lange kein neuer Schnee kommt.
- Wird ein Fenster bewegt, skaliert oder geschlossen, wird sein Schnee in fallende Flocken umgewandelt (mit kleinem Zufallsimpuls)
- Gerendert wird pro Oberfläche ein Triangle-Strip in Metal (weiß, leicht bläulicher Schatten). Die Vertices nur neu bauen, wenn sich die Heightmap geändert hat, höchstens mit 20 Hz.

### Fallende Flocken
- Struct mit `position`, `velocity`, `radius`, `swayPhase`, `opacity`. Pool mit fester Maximalgröße (Standard 800, maximal 2500)
- Bewegung: Fallgeschwindigkeit abhängig von der Größe, sinusförmiges Pendeln, dazu der globale Wind
- Wind: ruhige Grundbrise plus zufällige Böen (geglättetes Rauschen). Gelegentlich kurze „Flurries“ mit vielen Flocken.
- Kollision: pro Frame prüfen, ob die Flocke eine Oberkante innerhalb ihres x-Bereichs von oben gekreuzt hat. Bei ein paar Dutzend Oberflächen reicht das naiv aus.
- Rendering: alle aktiven Flocken werden pro Frame in einen vorallokierten `MTLBuffer` gepackt (`FlakeInstances.pack`, getestet) und mit einem einzigen instanzierten Draw-Call gezeichnet. Die Scheibe entsteht prozedural im Fragment-Shader. Nicht SpriteKit: 800 `SKSpriteNode`s kosteten allein durch die Property-Setter ca. 10 % CPU.

### Menüleiste und Einstellungen
- `MenuBarExtra` mit Schneeflocken-SF-Symbol. Optionen: An/Aus, Intensität (leicht / mittel / Schneesturm), Flockengröße, Wind, Modus „nur aktives Fenster“ oder „alle Fenster“, Schnee am Boden an/aus, „Schnee abschütteln“ (Reset), Launch at Login, Beenden
- Persistenz über `@AppStorage` / `UserDefaults`
- Launch at Login über `SMAppService.mainApp` (funktioniert nur im `.app`-Bundle)

## Performance-Ziele

- Unter 5 % CPU bei mittlerer Intensität auf einem M-Chip
- `preferredFramesPerSecond = 60`, im Akkubetrieb 30
- Pausieren bei Bildschirmsperre, Display-Sleep und Bildschirmschoner (`NSWorkspace`- bzw. `DistributedNotificationCenter`-Notifications)
- Keine Allokationen im Frame-Loop: Flocken kommen aus dem Pool, Instanz-Puffer sind dreifach vorallokiert

## Meilensteine

1. Transparentes Overlay auf dem Hauptbildschirm, Flocken fallen durch und verschwinden unten
2. Schneeverwehung am Bildschirmboden (Heightmap und Rendering)
3. Schnee bleibt auf dem **aktiven Fenster** liegen und fällt ab, wenn es bewegt wird
4. Alle sichtbaren Fenster inklusive Verdeckung
5. Mehrere Bildschirme
6. Menüleisten-Einstellungen und Persistenz
7. Wind, Böen und Schmelzen
8. `bundle.sh`, App-Icon und Launch at Login

Immer nur einen Meilenstein auf einmal umsetzen. Danach bauen, testen, committen und mich bitten, es visuell zu prüfen.

## Arbeitsregeln für Claude

- Du siehst meinen Bildschirm nicht. Nach visuellen Änderungen sag mir konkret, worauf ich achten soll, und warte auf mein Feedback, statt zu raten.
- Für Debugging einen versteckten Debug-Modus einbauen (Umgebungsvariable `SNOWPILE_DEBUG=1`): Oberflächen als rote Linien zeichnen, FPS und Flockenzahl anzeigen
- Für Koordinatenumrechnung, Verdeckung, Heightmap und Sandpile-Regel immer Tests schreiben, bevor ein Bug dort „gefixt“ wird
- Keine neuen Dependencies ohne Rückfrage
- Kleine Commits mit aussagekräftigen Messages auf Deutsch
- Code und Bezeichner auf Englisch, Kommentare nur, wo das *Warum* nicht offensichtlich ist
- Swift-Concurrency: UI und Rendering laufen auf `@MainActor`, das Fenster-Polling im Hintergrund. Ergebnisse als unveränderliche Snapshots an den Main Actor übergeben.
