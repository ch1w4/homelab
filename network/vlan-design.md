# ネットワーク・VLAN設計

> 最終更新: 2026-11-09

## 物理構成

```
[コミュファ光 ONU]
        │
[Aterm WH832A]  PPPoE ブリッジ ＋ 家族用 Wi-Fi（1階）
        │ 約20m（Cat6a）
[ハブ TL-SG105]  ── PPPoE と家族用 LAN を 2 台のルーターで共有
   │                         │
[NEC IX2215]  ◀── VRRP ──▶ [YAMAHA RTX1200]（待機系・検証中）
   │ GE2 port1〜4（静的 LAG）
[Allied Telesis AT-x210-24GT]
   ├── port1〜8   : access VLAN10（PC）
   ├── port9      : access VLAN50（検証）
   ├── port17〜19 : trunk VLAN 20/30/50/99 → Proxmox ①②③
   └── port21〜24 : sa1（IX2215 との LAG）
```

- Aterm は PPPoE ブリッジにして、IX2215 が直接 PPPoE を張る（NAT は 1 段）。
- 各 Proxmox ノードは LAN ポート 1 本を trunk にし、`vmbr0`（VLAN-aware）でタグを見て VM に振り分ける。

## VLAN 定義

| VLAN | 名前 | サブネット | ゲートウェイ | IX の口 | 用途 |
|---|---|---|---|---|---|
| — | 家族 | 192.168.0.0/24 | 192.168.0.254（VRRP） | GE0.0 | 家族用 LAN |
| 10 | 一般 | 192.168.10.0/24 | 192.168.10.1 | GE2.10 | 自分の PC・スマホ |
| 20 | サーバー | 192.168.20.0/24 | 192.168.20.1 | GE2.20 | DB・Git・VPN・監視・バックアップ |
| 30 | DMZ | 192.168.30.0/24 | 192.168.30.1 | GE2.30 | 外部公開（proxy01・mc01） |
| 50 | 検証 | 192.168.50.0/24 | 192.168.50.1（VRRP） | GE2.5 | テスト VM・VRRP 検証 |
| 99 | 管理 | 192.168.99.0/24 | 192.168.99.1 | GE2.9 | Proxmox・スイッチの管理 |

IX2215 のサブインターフェース番号は 0〜32 までのため、VLAN50 は GE2.5、VLAN99 は GE2.9 にしている（タグの VLAN ID は 50・99 のまま）。

## VLAN 間フィルタ（IX2215）

| 方向 | 許可/拒否 | 理由 |
|---|---|---|
| 一般（10）→ 全 VLAN | ✅ 許可 | 自分の PC から管理する |
| DMZ（30）→ サーバー（20） | 必要なポートだけ許可（DB など） | 公開サーバーが乗っ取られたときの横展開を防ぐ |
| DMZ（30）→ その他の内部 | ❌ 拒否 | 同上 |
| 管理（99）→ 他 VLAN | ❌ 拒否（監視・ログ送信など必要なものだけ許可） | 管理系を他から切り離す |
| 家族 → ラボの各 VLAN | ❌ 拒否 | 家族の端末からラボに入れないようにする |
| 各 VLAN → インターネット | ✅ 許可 | 更新・外部 API |
| インターネット → 内部 | ❌ 拒否（動的フィルタで戻りの通信だけ通す） | 外から入れる口を作らない |

## 冗長化

- **IX2215 ⇔ スイッチ**：4 本の静的 LAG（IX は LACP 非対応）。1〜3 本切れても通信が続く。
- **ゲートウェイ**：VLAN50 と家族用 LAN は IX2215 と RTX1200 の VRRP。IX2215 が止まると RTX1200 が仮想 IP を引き継ぎ、自分の PPPoE で外に出る（コミュファは 1 セッションのため両方オンデマンド）。
- 今後、RTX1200 を IX2215 の 2 台目に置き換え、全 VLAN を VRRP にする予定。

## 外部公開と管理アクセス

### Web：Cloudflare Tunnel
proxy01（DMZ）の cloudflared が Cloudflare に外向きでつなぎ、Nginx Proxy Manager から各アプリへ振り分ける。ルーターでポートを開けない。

### Minecraft：Oracle Cloud の中継サーバー
Cloudflare Tunnel はゲーム（TCP/UDP の生ポート）を通せないため、Oracle Cloud（Always Free・大阪）に relay01 を置いた。

```
プレイヤー → relay01 ─┬ TCP 25565 → HAProxy（PROXY protocol v2）─┐
                      └ UDP 19132 → iptables DNAT              ─┤ Tailscale
                                                                └→ vpn01 → mc01（Velocity）
```

- Tailscale の ACL で、relay01（`tag:relay`）が届くのは mc01 の 2 ポートだけ。
- Velocity 側は `haproxy-protocol = true`、Geyser も Velocity への接続で PROXY protocol を使う。

### 管理：Tailscale
vpn01（LXC）をサブネットルーターにして、VLAN 20/30/50/99 に外から入れるようにしている。SSH や管理画面はインターネットに一切出さない。

## 設計の意図

### なぜ VLAN を細かく分けたか
「公開するもの（DMZ）」「内部サービス（サーバー）」「管理（99）」「自分の端末（10）」「家族」で信頼度が違うため。公開サーバーや家族の端末に何かあっても、管理系や DB まで届かないようにしている。

### なぜ自宅の IP を出さないか
DNS は誰でも引けるので、自宅の IP を向けるとそのまま攻撃対象になる。Web は Cloudflare Tunnel、ゲームは中継サーバー経由にして、自宅側はポートを開けない構成にした。

### Tailscale を使う理由
- SSH や管理画面をインターネットに出さずに外から管理できる
- WireGuard を自前で管理するより、鍵・ACL の管理が楽
- ACL のテスト機能で「中継サーバーから SSH や DB に入れない」ことを保存のたびに確認できる
