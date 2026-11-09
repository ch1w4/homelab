# chiwa-lab — Home Lab Infrastructure

個人で構築・運用しているオンプレミスのホームラボです。
Proxmox VE 9 の3ノードクラスタを中心に、ゲームサーバー（Minecraft）・Webアプリ・基盤サービス（VPN・監視・バックアップ・Git）を動かしています。
ネットワークは NEC IX2215 と Allied Telesis AT-x210 で VLAN を分け、外部公開は Cloudflare Tunnel と Oracle Cloud の中継サーバー経由にして、自宅のグローバル IP を公開していません。

> 最終更新: 2026-11-09（現在稼働中の構成。計画中のものは「今後の予定」に分けて記載）

---

## 構成の概要

```
                         [Internet]
                             │
        ┌────────────────────┼─────────────────────────┐
        │                    │                         │
 [Cloudflare]        [Oracle Cloud 大阪]          [Tailscale]
  DNS / Tunnel        relay01（Always Free）       管理用 VPN
        │             HAProxy / iptables             │
        │                    │ Tailscale（tag:relay） │
        └──────────┐         │        ┌──────────────┘
                   ▼         ▼        ▼
        コミュファ光 ─ ONU ─ Aterm（PPPoE ブリッジ）─ ハブ
                                                     │
                              ┌──────────────────────┴──────────────┐
                              ▼                                     ▼
                     [NEC IX2215]  ◀─ VRRP（VLAN50・家族用LAN）─▶ [YAMAHA RTX1200]
                     PPPoE / NAT / VLAN間フィルタ                  待機系（検証中）
                              │ LAG ×4（802.1Q trunk）
                              ▼
                     [Allied Telesis AT-x210-24GT]
                              │ trunk（VLAN 20/30/50/99）
              ┌───────────────┼────────────────┐
              ▼               ▼                ▼
        ① pve-mc        ② pve-app        ③ pve-infra
        Minecraft       Web / DB / Git   VPN / 監視 / バックアップ
```

---

## ハードウェア

| ノード | ホスト名 | CPU / メモリ | ストレージ | 役割 |
|---|---|---|---|---|
| ① | pve-mc | Core i5-13400 / 64GB | SATA SSD 1TB（ZFS） | Minecraft 専用 |
| ② | pve-app | Core i7-9700K / 32GB | NVMe 512GB（ZFS）＋ HDD 2TB | Web・アプリ・DB・テスト |
| ③ | pve-infra | Core i5-8400 / 16GB | SATA SSD 500GB（ZFS）＋ HDD 3TB | VPN・監視・ログ・バックアップ |

| 機器 | 役割 |
|---|---|
| NEC UNIVERGE IX2215 | エッジルーター（PPPoE・NAT・VLAN 間フィルタ・DHCP・DNS キャッシュ） |
| YAMAHA RTX1200 | VRRP の待機系（VLAN50 と家族用 LAN、切替テスト待ち） |
| Allied Telesis AT-x210-24GT | L2 スイッチ（IX2215 とは静的 LAG ×4） |
| NEC Aterm WH832A | PPPoE ブリッジ・家族用 Wi-Fi |

ノードは全て静音・省電力を優先したデスクトップ機です（以前はラックサーバー2台構成）。

---

## ネットワーク

詳細は [network/vlan-design.md](network/vlan-design.md)。

| VLAN | 名前 | サブネット | 主な用途 |
|---|---|---|---|
| — | 家族 | 192.168.0.0/24 | 家族用 LAN（ラボには入れない） |
| 10 | 一般 | 192.168.10.0/24 | 自分の PC・スマホ |
| 20 | サーバー | 192.168.20.0/24 | DB・Git・VPN・監視・バックアップ |
| 30 | DMZ | 192.168.30.0/24 | 外部公開するもの（proxy01・mc01） |
| 50 | 検証 | 192.168.50.0/24 | テスト用 VM・VRRP 検証 |
| 99 | 管理 | 192.168.99.0/24 | Proxmox・スイッチなどの管理画面 |

---

## Proxmox クラスタ「chiwa-lab」

- Proxmox VE 9.2、3ノード・3票でクォーラム
- ストレージは各ノードの ZFS（local-zfs）、バックアップは Proxmox Backup Server（pbs01）
- **HA**：ノードが止まると別のノードで自動起動（ZFS レプリケーションで②⇔③にディスクを複製）
- VMID は「VLAN 番号 ＋ IP の末尾」（例：2040 → 192.168.20.40）

| VMID | 名前 | 種類 | ノード | 内容 | HA |
|---|---|---|---|---|---|
| 3020 | mc01 | VM | ① | Velocity＋Geyser/Floodgate、lobby・survival（Paper） | — |
| 3010 | proxy01 | VM | ② | Nginx Proxy Manager＋cloudflared | ◯ |
| 2040 | db01 | LXC | ② | PostgreSQL 17 | ◯ |
| 2045 | git01 | LXC | ② | Forgejo（自前 Git） | — |
| 2050 | docker01 | VM | ② | 個人サイト・Web アプリ（Docker Compose） | — |
| 2051 | docker02 | VM | ② | 学校課題の Web アプリ（Docker Compose） | — |
| 5020 | mctest01 | VM | ② | Minecraft プラグインのテストサーバー（VLAN50） | — |
| 2015 | vpn01 | LXC | ③ | Tailscale サブネットルーター＋exit node | ◯ |
| 2020 | pbs01 | VM | ③ | Proxmox Backup Server（HDD 3TB） | — |
| 2025 | log01 | LXC | ③ | rsyslog（ルーター・スイッチのログを 90 日保存） | — |
| 2030 | mon01 | LXC | ③ | Uptime Kuma（死活監視 → Discord 通知） | ◯ |
| 2035 | vault01 | LXC | ③ | Vaultwarden（Tailscale 経由のみ） | ◯ |
| 2055 | runner01 | VM | ③ | Forgejo Runner（push で自動デプロイ） | — |

---

## 外部公開

| 種類 | 経路 | ポイント |
|---|---|---|
| Web | Cloudflare → **Cloudflare Tunnel** → proxy01 → 各アプリ | ルーターでポートを開けない |
| Minecraft | プレイヤー → **relay01（Oracle Cloud 大阪）** → Tailscale → mc01 | Java 版は HAProxy の PROXY protocol v2 で本当の IP を渡す。統合版（UDP）は iptables で転送 |
| 管理 | 自分の端末 → Tailscale → vpn01 → 各管理画面 | SSH・管理画面はインターネットに出さない |

relay01 は Tailscale の ACL で **mc01 のゲームポート（TCP 25565 / UDP 19132）だけ**に通信を絞っています。中継サーバーが乗っ取られてもラボ全体には入れません。

---

## バックアップと運用

- **バックアップ**：毎日 3:00 に全 VM/LXC を pbs01 へ（暗号化・検証あり）。mc01 は 4:30（直前にワールドを保存）。pbs01 自身は毎月②の HDD へ。
- **監視**：Uptime Kuma で Web・Minecraft・DB・Proxmox・ルーターを監視し、Discord に通知。
- **ログ**：IX2215・スイッチの syslog を log01 に集約（90 日）。
- **デプロイ**：Forgejo に push すると Forgejo Runner が docker01 に自動反映。
- **障害対応の記録**：③の NIC（Intel I219-V / e1000e）がハングしてフェンシング → HA 対象は自動復旧。NIC のオフロード無効化で再発を防止。

---

## セキュリティ方針

- 自宅のグローバル IP は公開しない（Web は Tunnel、ゲームは中継サーバー経由）
- 管理アクセスは Tailscale 経由のみ。管理用 VLAN99 は他の VLAN から切り離す
- VLAN 間は IX2215 のフィルタで必要な通信だけ許可（DMZ から内部へは入れない）
- パスワード・トークンは Vaultwarden で管理し、`.env` はリポジトリに含めない
- このリポジトリにはプライベート IP のみ記載

---

## 今後の予定

- [ ] IX2215 を2台にして全 VLAN を VRRP 化（RTX1200 を置き換え）、回線断の切替（watch-group）
- [ ] 無線 AP（SSID ごとに VLAN）とゲスト用 VLAN60
- [ ] Prometheus・Grafana・Alertmanager による監視基盤、Loki・Oxidized
- [ ] 3ノードを 10GbE で直結（フルメッシュ）し、Ceph で HA 対象を共有ストレージ化
- [ ] UPS と NUT による停電時の自動シャットダウン
- [ ] Ansible による初期セットアップの自動化

---

## 学んだこと

- Proxmox クラスタ・HA・ZFS レプリケーション・PBS によるバックアップ設計
- IX2215 での VLAN・サブインターフェース・VLAN 間フィルタ・VRRP・静的 LAG
- Cloudflare Tunnel と Oracle Cloud＋Tailscale を使った「ポートを開けない」外部公開
- HAProxy の PROXY protocol と、それを受ける側（Velocity・Geyser）の設定の整合
- NIC 障害からの HA の自動復旧と、原因（e1000e のハング）の切り分け
