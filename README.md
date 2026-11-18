# Snowsill

Schnee für den macOS-Desktop. Snowsill ist eine kleine Menüleisten-App, die Schnee über den Bildschirm fallen lässt.
Er bleibt auf den Oberkanten der Fenster, auf Widgets, Schreibtisch-Icons und am unteren Bildschirmrand liegen,
rutscht ab, wenn man ein Fenster schnell zieht, und schmilzt langsam weg.

Privates Spaßprojekt: kein App Store, keine Sandbox, keine Abhängigkeiten von Drittanbietern.

## Was es kann

- **Schnee auf Fenstern:** Jedes sichtbare Fenster bekommt eine bucklige Schneekappe. Verdeckte Teile einer Oberkante
  bleiben frei. Verschiebt man ein Fenster, wandert der Schnee mit. Bei schnellem Ziehen, beim Verkleinern, Schließen
  oder Minimieren fällt er als Klumpen und Pulver herunter.
- **Schneeverwehung am Boden:** Am unteren Bildschirmrand wächst eine Schneeschicht mit ausgefranster Oberkante.
- **Schneekugeln und Schneemänner:** Über genug Schnee wird der Cursor zur Hand. Ziehen rollt eine Kugel, die mit dem
  aufgesammelten Schnee wächst. Drei gestapelte Kugeln ergeben einen Schneemann mit Augen, Karottennase, Knöpfen, Armen
  und Hut. Greift man die unterste Kugel, trägt man den ganzen Schneemann, auch auf ein Fenster. Ein Doppelklick lässt
  ihn zerplatzen. Klicks in Fenster gehen dabei immer durch.
- **Schneeschaufler:** Wird der Bodenschnee zu hoch, fährt ein kleines Räumfahrzeug durch und schiebt einen Wall vor sich
  her. Ist der Boden fast voll, etwa im Schneesturm, kommt es schon nach einer halben Minute wieder. Schneemänner
  bleiben stehen: Es fährt hinter ihnen durch, räumt den Schnee unter ihnen weg, und sie sinken auf den Boden.
- **Eiszapfen:** Liegt länger Schnee auf einem Fenster, wachsen an seiner Unterkante Eiszapfen. Bei schnellem Bewegen
  brechen sie ab.
- **Wind und Wetter:** Ruhige Brise mit Böen, ab und zu ein kurzes Schneegestöber. Liegender Schnee schmilzt langsam,
  schneller, wenn lange nichts nachkommt.
- **Mehrere Bildschirme:** Jeder angeschlossene Bildschirm bekommt sein eigenes Schneetreiben.
- **Vollbildmodus:** Auf Wunsch fällt über Apps im Vollbildmodus kein Schnee, und zwar nur auf dem Bildschirm, auf dem
  die App im Vollbild läuft.

## Voraussetzungen

- macOS 14 oder neuer, Apple Silicon
- Swift 6 Toolchain (Xcode oder die Command Line Tools reichen)

## Bauen und starten

```sh
./scripts/bundle.sh && open Snowsill.app   # App-Bundle bauen und starten
swift run Snowsill                          # direkt aus dem Quellcode starten
```

`bundle.sh` baut eine Release-Version, erzeugt das App-Icon und signiert das Bundle ad hoc. „Beim Anmelden starten“
funktioniert nur aus dem Bundle. Es läuft immer nur eine Instanz.

Das Bundle ist nur ad hoc signiert, nicht notarisiert. Auf dem Mac, auf dem es gebaut wurde, startet es normal. Kopiert
man `Snowsill.app` auf einen anderen Mac, blockiert Gatekeeper den ersten Start. Dann in den Systemeinstellungen unter
„Datenschutz & Sicherheit“ auf „Trotzdem öffnen“ klicken, oder die App dort einfach selbst bauen.

## Bedienung

Alles läuft über das Schneeflocken-Symbol in der Menüleiste:

| Einstellung                     | Wirkung                                                         |
| ------------------------------- | --------------------------------------------------------------- |
| Schnee                          | An/Aus                                                          |
| Intensität                      | leicht, mittel, Schneesturm                                     |
| Flockengröße                    | klein, normal, groß                                             |
| Wind                            | windstill, Brise, stürmisch                                     |
| Schnee liegt auf                | allen Fenstern oder nur dem aktiven                             |
| Schnee am Boden                 | Verwehung am unteren Bildschirmrand                             |
| Schneeschaufler                 | Räumfahrzeug am Boden                                           |
| Schneemänner bauen              | Kugeln rollen und stapeln                                       |
| Eiszapfen                       | Eiszapfen an Fensterunterkanten                                 |
| Schnee auf Widgets              | Schnee auf den Widgets des Schreibtischs                        |
| Schnee im Vollbildmodus         | aus: kein Schnee über Apps im Vollbildmodus                     |
| Schnee auf Schreibtisch-Icons   | braucht die Berechtigung „Bedienungshilfen“ (siehe unten)       |
| Schnee abschütteln              | entfernt allen liegenden Schnee, Kugeln und Eiszapfen           |
| Beim Anmelden starten           | Launch at Login (nur im `.app`-Bundle)                          |
| Snowsill beenden                | beendet die App (⌘Q)                                            |

Die Einstellungen bleiben über Neustarts erhalten.

## Berechtigungen

Snowsill liest nur Position und Größe der Fenster, keine Fenstertitel oder Inhalte. Deshalb braucht es **keine**
Bildschirmaufnahme-Berechtigung.

Nur für Schnee auf Schreibtisch-Icons fragt macOS beim Einschalten nach „Bedienungshilfen“, weil die Positionen der
Icons über die Accessibility-API gelesen werden. Ohne Freigabe bleiben die Icons einfach schneefrei.

## Performance

Ziel ist unter 5 % CPU bei mittlerer Intensität. Gezeichnet wird mit Metal in einem einzigen instanzierten Draw-Call.
Die Bildrate passt sich an: 60 fps, solange ein Fenster bewegt wird oder die Maus über Schnee ist, sonst 30 fps, im
Akkubetrieb und Stromsparmodus immer 30. Bei Bildschirmsperre, Ruhezustand des Displays und Bildschirmschoner pausiert
Snowsill.

## Entwicklung

```sh
swift build    # bauen
swift test     # Logik-Tests (swift-testing)
```

### Aufbau

```
Sources/Snowsill/        App, Overlay-Fenster, Fenster-Polling, Metal-Rendering, Snapshot-Modus
Sources/SnowsillCore/    reine Logik ohne AppKit/Metal: Simulation, Heightmaps, Verdeckung, Kugeln,
                         Schaufler, Eiszapfen, Wind, Koordinaten, Instanzdaten fürs Rendering
Tests/SnowsillTests/     Tests für SnowsillCore
```

Die Simulation rechnet komplett in CG-Koordinaten (Ursprung oben links) und ist von AppKit und Metal getrennt, deshalb
lässt sie sich ohne Bildschirm testen. Mehr Details zu Architektur und Designentscheidungen stehen in
[`CLAUDE.md`](CLAUDE.md).

### Snapshot-Modus

Spielt ein Szenario mit simulierten Fenstern auf einer virtuellen Uhr ab (fester Seed, schneller als Echtzeit),
rendert offscreen und schreibt Bilder und Statistiken nach `snapshots/<szenario>/`:

```sh
SNOWSILL_SNAPSHOT=drag swift run Snowsill
```

Szenarien: `drag`, `close`, `ground`, `overlap`, `plow`, `snowman`, `carry`, `icicles`, `secondary`, `widgets`,
`wind`, `icons`. Ausgabe: `sheet.png` (Übersicht), `tNNN.NN.png` (ganzer Bildschirm), `detail_*.png` (2×-Ausschnitt)
und `stats.txt`. Mit `SNOWSILL_SNAPSHOT_OUT=<ordner>` lässt sich der Zielordner ändern.

### Weitere Umgebungsvariablen

| Variable                     | Zweck                                                                    |
| ---------------------------- | ------------------------------------------------------------------------ |
| `SNOWSILL_DEBUG=1`           | Oberflächen als rote Linien, FPS und Flockenzahl einblenden               |
| `SNOWSILL_SELFTEST=mouse`    | Mauspfad live prüfen (Hover, Klick-Durchlass, Schneemann bauen)           |
| `SNOWSILL_LOGIN_ITEM=status` | Login-Objekt prüfen oder setzen (`status`, `on`, `off`), nur im Bundle    |
| `SNOWSILL_ICONS=list`        | erkannte Schreibtisch-Icons ausgeben                                      |

Beispiele:

```sh
SNOWSILL_LOGIN_ITEM=status Snowsill.app/Contents/MacOS/Snowsill
open -W --env SNOWSILL_ICONS=list --stdout /tmp/icons.txt Snowsill.app && cat /tmp/icons.txt
```

## Lizenz

MIT, siehe [`LICENSE`](LICENSE).
