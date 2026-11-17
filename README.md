# SnowPile

Schnee für den macOS-Desktop: Flocken fallen über den Bildschirm, bleiben auf Fenstern, Widgets und am Boden liegen,
rutschen beim Ziehen ab und schmelzen langsam. Aus Bodenschnee lassen sich Kugeln rollen und Schneemänner bauen,
ein kleiner Schaufler räumt ab und zu den Boden, unter verschneiten Fenstern wachsen Eiszapfen.

```sh
./scripts/bundle.sh && open SnowPile.app   # App bauen und starten (nötig für „Beim Anmelden starten“)
swift run SnowPile                          # direkt starten
swift test                                  # Logik-Tests
```

Bedienung über das Schneeflocken-Symbol in der Menüleiste. macOS 14+, Apple Silicon.
