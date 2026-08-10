# TSPlayerKit

[![Swift 6.3](https://img.shields.io/badge/Swift-6.3-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%20%7C%20iOS%20%7C%20tvOS%20%7C%20visionOS-blue.svg)](#requirements)
[![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)

**Lire des fichiers vidéo `.ts` (Transport Stream) avec AVPlayer, sans transcodage ni dépendance externe. Compatible iOS 17+.**

---

## Problème résolu

Apple bloque nativement la lecture des fichiers `.ts` bruts par `AVFoundation` en dehors d'une structure HLS (`.m3u8`). Les approches classiques imposent :

- L'intégration d'outils C pour **remuxer** la vidéo en `.mp4` avant lecture
- Des dépendances lourdes type `ffmpeg`
- Une complexité qui alourdit le binaire et le code

**TSPlayerKit** élimine cette contrainte avec une approche 100% Swift, sans dépendance, en **simulant un flux HLS virtuel** servi directement depuis le disque.

---

## Comment ça marche

> **Note iOS 17+** — Depuis iOS 17, le moteur HLS d'Apple rejette le chargement manuel des segments via `AVAssetResourceLoaderDelegate`. TSPlayerKit utilise désormais un **serveur HTTP local** (basé sur le framework natif `Network`) — zéro dépendance externe.

```
┌─────────────────────────────────────────────────────┐
│                    AVPlayer                          │
│  "Je veux lire http://127.0.0.1:[port]/playlist.m3u8"│
└──────────────┬──────────────────────────────────────┘
               │ ① Requête HTTP GET standard
               ▼
┌─────────────────────────────────────────────────────┐
│          LocalHTTPServer (NWListener)                │
│  Route GET /playlist.m3u8                           │
│  → Retourne le .m3u8 en mémoire (200 OK)            │
└──────────────┬──────────────────────────────────────┘
               │ ② AVPlayer demande le segment TS via HTTP
               ▼
┌─────────────────────────────────────────────────────┐
│          LocalHTTPServer (NWListener)                │
│  Route GET /segment.ts                              │
│  → Parse le Header "Range: bytes=start-end"         │
│  → FileStreamer.readBytes(offset:, length:)          │
│  → Retourne 206 Partial Content avec les octets     │
└─────────────────────────────────────────────────────┘
```

1. **Serveur HTTP local** — `LocalHTTPServer` démarre sur un port loopback aléatoire via `NWListener` (framework `Network`, sans dépendance)
2. **Playlist HLS virtuelle** — Générée en mémoire, elle déclare le `.ts` comme unique segment via `http://127.0.0.1:[port]/segment.ts`
3. **Lecture disque à la volée** — `FileStreamer` lit les plages d'octets demandées par les requêtes `Range` HTTP, avec support complet du **seek**

---

## Installation

### Swift Package Manager

Dans ton `Package.swift` :

```swift
dependencies: [
    .package(url: "https://github.com/Theorhd/TSPlayerKit.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: ["TSPlayerKit"]
    ),
]
```

Ou dans Xcode : **File → Add Packages…** → colle l'URL du dépôt.

---

## Utilisation

### Lecture basique

```swift
import TSPlayerKit
import AVFoundation

// 1. Créer un TSPlayerItem depuis un fichier local .ts
let tsFileURL = Bundle.main.url(forResource: "video", withExtension: "ts")!
let tsItem = try TSPlayerItem(tsFileURL: tsFileURL)

// 2. Créer l'AVPlayer et lire
let player = AVPlayer(playerItem: tsItem.playerItem)
player.play()
```

### Dans SwiftUI

```swift
import SwiftUI
import AVKit
import TSPlayerKit

struct VideoPlayerView: View {
    let tsFileURL: URL

    var body: some View {
        if let tsItem = try? TSPlayerItem(tsFileURL: tsFileURL) {
            VideoPlayer(player: AVPlayer(playerItem: tsItem.playerItem))
        } else {
            ContentUnavailableView(
                "Impossible de lire la vidéo",
                systemImage: "video.slash",
                description: Text("Le fichier .ts n'a pas pu être ouvert.")
            )
        }
    }
}
```

### Avec UIKit (AVPlayerViewController)

```swift
import UIKit
import AVKit
import TSPlayerKit

func playVideo(from tsURL: URL) throws {
    let tsItem = try TSPlayerItem(tsFileURL: tsURL)
    let player = AVPlayer(playerItem: tsItem.playerItem)

    let controller = AVPlayerViewController()
    controller.player = player

    present(controller, animated: true) {
        player.play()
    }
}
```

### Ajuster la durée cible du segment

```swift
// Pour une vidéo de 2 heures, augmente le targetDuration
// pour que la playlist reflète une durée plus réaliste
let tsItem = try TSPlayerItem(
    tsFileURL: videoURL,
    targetDuration: 7200.0  // 2 heures en secondes
)
```

### Téléchargement + lecture

```swift
func downloadAndPlay(from remoteURL: URL) async throws {
    // Télécharge le .ts localement
    let (localURL, _) = try await URLSession.shared.download(from: remoteURL)

    // Crée le player item
    let tsItem = try TSPlayerItem(tsFileURL: localURL)

    // Joue sur le thread principal
    await MainActor.run {
        let player = AVPlayer(playerItem: tsItem.playerItem)
        player.play()
    }
}
```

---

## API Reference

### `TSPlayerItem`

Point d'entrée principal. Wrapper qui produit un `AVPlayerItem` configuré pour la lecture d'un fichier `.ts`.

```swift
public struct TSPlayerItem {
    /// L'AVPlayerItem prêt à être lu par AVPlayer.
    public let playerItem: AVPlayerItem

    /// Crée un player item pour un fichier .ts local.
    /// - Parameters:
    ///   - tsFileURL: L'URL locale du fichier .ts
    ///   - targetDuration: Durée déclarée dans le manifeste HLS (secondes, défaut: 10)
    /// - Throws: FileStreamerError si le fichier est inaccessible
    public init(tsFileURL: URL, targetDuration: Double = 10.0) throws
}
```

### `FileStreamerError`

Erreurs pouvant survenir lors de la lecture du fichier.

| Cas | Description |
|---|---|
| `.cannotOpenFile(URL)` | Le fichier `.ts` n'existe pas ou est inaccessible en lecture |
| `.systemError(Error)` | Erreur système sous-jacente (permissions, E/S) |
| `.offsetOutOfRange(offset:fileSize:)` | L'offset demandé dépasse la taille du fichier |
| `.deinitialized` | Le streamer a été désalloué pendant une opération |

---

## Structure du package

```
Sources/TSPlayerKit/
├── TSPlayerItem.swift              ← API publique (wrapper lecture locale)
├── AdStrippingProxy.swift          ← Proxy HLS anti-pub (v1.1.0)
├── HLSPlaylistCleaner.swift        ← Détection de pubs + rewriting de playlist
├── RemotePlaylistFetcher.swift     ← Fetch HTTP distant (playlists + segments)
├── LocalHTTPServer.swift           ← Serveur HTTP local (NWListener)
├── HLSManifestGenerator.swift      ← Génération du .m3u8 virtuel
└── FileStreamer.swift              ← Lecture disque asynchrone (FileHandle)
```

| Composant | Rôle |
|---|---|
| `TSPlayerItem` | Wrapper qui démarre le serveur, génère le manifest et assemble l'`AVPlayerItem` |
| `AdStrippingProxy` | Proxy HTTP local qui nettoie les pubs d'un flux HLS distant |
| `HLSPlaylistCleaner` | Détection des segments publicitaires (CUE, patterns URL, durées) et réécriture des playlists |
| `RemotePlaylistFetcher` | Fetch HTTP de playlists et segments depuis un CDN distant (via URLSession) |
| `LocalHTTPServer` | Serveur HTTP local basé sur `NWListener` : sert le manifest et les segments TS via HTTP standard |
| `HLSManifestGenerator` | Génère la chaîne `.m3u8` avec les URLs `http://127.0.0.1:[port]/...` |
| `FileStreamer` | Lecture thread-safe du fichier via `FileHandle`, avec support byte-range pour le seek |

---

## Requirements

| Plateforme | Version minimum |
|---|---|
| macOS | 10.15+ |
| iOS | 13.0+ (compatible iOS 17+) |
| tvOS | 13.0+ |
| visionOS | 1.0+ |
| Swift | 6.3+ |
| Frameworks | `AVFoundation`, `Foundation`, `Network` |

---

## Ad Blocking — Proxy HLS local

Depuis la version 1.1.0, TSPlayerKit inclut `AdStrippingProxy`, un proxy HTTP local qui nettoie les flux HLS en retirant les segments publicitaires avant de les passer à AVPlayer.

```swift
import TSPlayerKit

// 1. Créer un fetcher (avec les headers requis par la source)
let fetcher = RemotePlaylistFetcher(
    userAgent: "Mozilla/5.0 ...",
    extraHeaders: ["Client-Id": "xxx"]
)

// 2. Démarrer le proxy sur un flux distant
let streamURL = URL(string: "https://usher.ttvnw.net/...")!
let proxy = try AdStrippingProxy(remoteURL: streamURL, fetcher: fetcher)

// 3. Lire via le proxy (pense à garder une référence forte !)
let player = AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: proxy.localURL)))
player.play()
```

**Fonctionnement** : le proxy expose `http://127.0.0.1:{port}/master.m3u8`. AVPlayer lit depuis cette URL locale. Le proxy fetch le flux original, détecte et retire les pubs (tags SCTE35/CUE, patterns d'URL, heuristiques de durée), puis sert un playlist nettoyé.

**Modes de segments** :
- `.stream` (défaut) — le proxy fetch et relaye les bytes des segments
- `.redirect` — HTTP 302 vers le CDN original (moins de bandwidth, mais AVPlayer peut mal le gérer)

---

## Limitations

- **Un seul segment** — La playlist ne déclare qu'un seul segment TS. Pour des vidéos multi-segments, le manifeste devrait être enrichi.
- **Pas de chiffrement** — Les fichiers doivent être en clair (pas de FairPlay DRM).
- **Performances disque** — `FileHandle` lit de manière synchrone sur une queue dédiée. Pour des fichiers très volumineux (>10 Go), le seek peut introduire une latence perceptible.
- **Codecs supportés** — Dépend des capacités d'`AVFoundation` sur l'appareil. Les codecs non supportés par la plateforme ne seront pas lus.
- **Proxy HLS** — La détection des pubs est conservatrice. Certaines pubs utilisant le SSAI sans marqueurs peuvent ne pas être détectées.

---

## License

MIT — voir le fichier [LICENSE](LICENSE).

---

## Contributing

Les contributions sont les bienvenues. Ouvre une issue pour discuter de ce que tu souhaites changer avant de soumettre une PR.

1. Fork le dépôt
2. Crée une branche (`git checkout -b feature/ma-fonctionnalite`)
3. Commit tes changements
4. Push et ouvre une Pull Request

---

<p align="center">
  <sub>Construit avec ❤️ pour la communauté Apple — zéro dépendance, 100% Swift.</sub>
</p>
