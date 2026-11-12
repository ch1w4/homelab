# chiwa-lab — Home Lab Infrastructure

個人で構築・運用しているオンプレミスのホームラボです。
Proxmox VE 9 の3ノードクラスタを中心に、ゲームサーバー（Minecraft）・Webアプリ・基盤サービス（VPN・監視・バックアップ・Git）を動かしています。
ネットワークは NEC IX2215 と Allied Telesis AT-x210 で VLAN を分け、外部公開は Cloudflare Tunnel と Oracle Cloud の中継サーバー経由にして、自宅のグローバル IP を公開していません。

> 最終更新: 2026-11-13 夜（現在稼働中の構成。計画中のものは「今後の予定」に分けて記載）

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
                     [NEC IX2215 #1]  ◀── VRRP（全VLAN）──▶  [NEC IX2215 #2]
                     Master・PPPoE / NAT / フィルタ          Backup・PPPoE 待機
                              │ LAG ×4                              │ LAG ×4
                              └──────────▶ [Allied Telesis AT-x210-24GT] ◀──────────┘
                                                 │ trunk（VLAN 20/30/50/99）・AP 用 trunk（10/50/60/99）
              ┌───────────────┼────────────────┐
              ▼               ▼                ▼
        ① pve-mc        ② pve-app        ③ pve-infra
        Minecraft       Web / DB / Git   VPN / 監視 / バックアップ
              └──── 10GbE 直結（Ceph・フルメッシュ）────┘
```

---

## ハードウェア

| ノード | ホスト名 | CPU / メモリ | ストレージ | 役割 |
|---|---|---|---|---|
| ① | pve-mc | Core i5-13400 / 64GB | SATA SSD 1TB（ZFS）＋ Ceph 用 SSD 480GB | Minecraft 専用 |
| ② | pve-app | Core i7-9700K / 32GB | NVMe 512GB（ZFS）＋ HDD 2TB ＋ Ceph 用 SSD 480GB | Web・アプリ・DB・テスト |
| ③ | pve-infra | Core i5-8400 / 16GB | SATA SSD 500GB（ZFS）＋ HDD 3TB ＋ Ceph 用 SSD 480GB | VPN・監視・ログ・バックアップ |

- 3台とも Mellanox ConnectX-4 Lx（10GbE・2ポート）を挿し、SFP+ DAC 3本で三角形に直結（スイッチなし）
- Ceph 用 SSD は停電保護（PLP）付きの Intel DC S3520 480GB

| 機器 | 役割 |
|---|---|
| NEC UNIVERGE IX2215 ×2 | エッジルーター（PPPoE・NAT・VLAN 間フィルタ・DHCP・DNS キャッシュ）。全 VLAN を VRRP で冗長化 |
| Allied Telesis AT-x210-24GT | L2 スイッチ（IX2215 2台とそれぞれ静的 LAG ×4） |
| BUFFALO WAPM-1166D | 無線 AP（SSID ごとに VLAN：lab=10・test=50・guest=60）。PoE は TP-Link TL-SG1005P |
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
| 60 | ゲスト | 192.168.60.0/24 | SSID guest（インターネットだけ） |
| 99 | 管理 | 192.168.99.0/24 | Proxmox・スイッチ・IX・AP の管理画面 |
| — | Ceph | 192.168.100.0/24 | 10GbE 直結（スイッチ・ルーターを通らない） |

---

### 冗長化（2026-11-13 構築）

- **ゲートウェイ**：IX2215 2台で全 VLAN と家族用 LAN を VRRP（仮想 IP は各 VLAN の `.1`、実 IP は #1 `.252`／#2 `.253`）。#1 が優先度 200 で Master、preempt は両方なし。
- **PPPoE**：コミュファは同じ ID で 2 セッションまで張れるので、2台とも常時接続。#1 の電源断テストで、切り替えは約 3 秒。
- **DHCP**：範囲を前半（#1）・後半（#2）に分けて、2台とも配る。
- **LAG**：IX は LACP 非対応なので静的 LAG ×4 を2組（スイッチ側は edgeport にして、つないだ直後に STP で止まらないようにした）。

---

## Proxmox クラスタ「chiwa-lab」

- Proxmox VE 9.2、3ノード・3票でクォーラム
- ストレージは各ノードの ZFS（local-zfs）と **Ceph**（共有ストレージ）、バックアップは Proxmox Backup Server（pbs01）
- **Ceph**：3台で MON・MGR・OSD を1つずつ、プール `ceph-vm`（3重・約440GB）。通信は 10GbE のフルメッシュ（PVE 9 の SDN Fabrics・OpenFabric）で、1本切れても遠回りして通じる。iperf3 で 9.4Gbps
- **HA**：HA 対象7台のディスクは Ceph 上にあり、ノードが止まると別のノードで「止まった瞬間のデータのまま」自動起動。ライブマイグレーションも数秒
- HA のノードアフィニティ：Web/DB は②優先→③、基盤は③優先→②、docker01 は②優先→①（③のメモリ不足のため）
- VMID は「VLAN 番号 ＋ IP の末尾」（例：2040 → 192.168.20.40）

| VMID | 名前 | 種類 | ノード | 内容 | HA |
|---|---|---|---|---|---|
| 3020 | mc01 | VM | ① | Velocity＋Geyser/Floodgate、lobby・survival（Paper） | — |
| 3010 | proxy01 | VM | ② | Nginx Proxy Manager＋cloudflared | ◯ |
| 2040 | db01 | LXC | ② | PostgreSQL 17 | ◯ |
| 2045 | git01 | LXC | ② | Forgejo（自前 Git） | ◯ |
| 2050 | docker01 | VM | ② | 個人サイト・Web アプリ（Docker Compose） | ◯ |
| 2051 | docker02 | VM | ② | 学校課題の Web アプリ（Docker Compose） | — |
| 5020 | mctest01 | VM | ② | Minecraft プラグインのテストサーバー（VLAN50） | — |
| 2015 | vpn01 | LXC | ③ | Tailscale サブネットルーター＋exit node | ◯ |
| 2020 | pbs01 | VM | ③ | Proxmox Backup Server（HDD 3TB） | — |
| 2025 | log01 | LXC | ③ | rsyslog（ルーター・スイッチのログを 90 日保存） | — |
| 2030 | mon01 | LXC | ③ | Uptime Kuma（死活監視 → Discord 通知） | ◯ |
| 2035 | vault01 | LXC | ③ | Vaultwarden（Tailscale 経由のみ） | ◯ |
| 2055 | runner01 | VM | ② | Forgejo Runner（push で自動デプロイ） | — |

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

- [x] IX2215 を2台にして全 VLAN を VRRP 化（RTX1200 を置き換え）（2026-11）
- [x] 無線 AP（SSID ごとに VLAN）とゲスト用 VLAN60（2026-11）
- [ ] 回線だけ切れたときの切替（watch-group）
- [ ] Prometheus・Grafana・Alertmanager による監視基盤、Loki・Oxidized
- [x] 3ノードを 10GbE で直結（フルメッシュ）し、Ceph で HA 対象を共有ストレージ化（2026-11）
- [ ] ③のメモリを 32GB に増設
- [ ] UPS と NUT による停電時の自動シャットダウン
- [ ] Ansible による初期セットアップの自動化

---

## 学んだこと

- Proxmox クラスタ・HA・ZFS レプリケーション・PBS によるバックアップ設計
- 10GbE フルメッシュ（OpenFabric）と Ceph による共有ストレージ、HA ノードアフィニティでの配置設計
- IX2215 での VLAN・サブインターフェース・VLAN 間フィルタ・VRRP・静的 LAG
- VRRP と PPPoE のセッション数の関係（急な電源断のあと古いセッションが残り、復帰した #1 がしばらくつながらない）
- AP（WAPM-1166D）の有線ポートを「Multiple（タグなし＋タグ付き）」にすると AP の中で VLAN が混ざり、ゲートウェイに届かなくなった。スイッチの MAC アドレス表で VRRP の仮想 MAC が別の VLAN に見えていることから特定し、全部タグ付きにして解決
- IX の設定を startup-config から作り直したら、`write memory` していなかった dmz-in の許可（mc01 → vpn01 の返事）が消えてマイクラが止まった。vpn01 が Tailscale の通信を自分の IP に書き換える（SNAT）ことを確かめて原因を特定した。設定の控えは running-config で取る
- Cloudflare Tunnel と Oracle Cloud＋Tailscale を使った「ポートを開けない」外部公開
- HAProxy の PROXY protocol と、それを受ける側（Velocity・Geyser）の設定の整合
- NIC 障害からの HA の自動復旧と、原因（e1000e のハング）の切り分け
