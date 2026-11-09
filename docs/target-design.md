# 目標の構成（完成形）

> 最終更新: 2026-11-09
> このファイルは **これから作る完成形** です。今動いている構成は [README](../README.md) を見てください。
> 「状態」の列で、完了・構築中・予定を分けています。

## 何が変わるか

| 項目 | 今 | 完成形 | 状態 |
|---|---|---|---|
| ルーター | IX2215 ＋ RTX1200（VLAN50・家族用 LAN だけ VRRP） | IX2215 ×2台で **全 VLAN を VRRP** | 予定 |
| 回線だけ切れたとき | 切り替わらない | watch-group で外への ping を見て #2 に切替 | 予定 |
| 無線 | Aterm の Wi-Fi（1階）だけ | WAPM-1166D（2階）、SSID ごとに VLAN | 予定 |
| ゲスト | なし | VLAN60（インターネットだけ） | 予定 |
| 監視 | Uptime Kuma | Prometheus・Alertmanager・Grafana ＋ 外からの相互監視 | 予定 |
| ログ | rsyslog | ＋ Loki（Grafana で検索）、Oxidized（設定の履歴） | 予定 |
| ノード間 | 1GbE（スイッチ経由） | **10GbE を3台で直結（フルメッシュ）** | 構築中（NIC・ケーブル購入済み） |
| HA のディスク | ZFS レプリケーション（最大15分戻る） | **Ceph**（戻らない・ライブマイグレーションが数秒） | 構築中（SSD 購入中） |
| 停電 | 対策なし | UPS ＋ NUT で自動シャットダウン | 予定 |

## ネットワーク

```
[コミュファ光 ONU] ─ [Aterm（PPPoE ブリッジ）] ─ [ハブ]
                                                 │
                         ┌───────────────────────┴───────────────────────┐
                         ▼                                               ▼
              [IX2215 #1  Master 優先度200]  ◀── VRRP ──▶  [IX2215 #2  Backup 優先度100]
                         │ 静的 LAG ×4                                    │ 静的 LAG ×2
                         └──────────────▶ [AT-x210-24GT] ◀────────────────┘
                                             │
                     ┌──────────────┬────────┼────────┬───────────────┐
                     ▼              ▼        ▼        ▼               ▼
                  メインPC        ① pve-mc ② pve-app ③ pve-infra   PoE スイッチ → 無線 AP
                                     └──── 10GbE 直結（Ceph）────┘
```

### VRRP の設計

- 仮想 IP は今のゲートウェイのまま（各 VLAN の `.1`、家族用は `192.168.0.254`）。端末の設定は変えない。
- 実 IP は #1 = `.252`、#2 = `.253`（家族用は `.2` / `.3`）。VRID は VLAN 番号と同じ（家族用は 1）。
- PPPoE は 2 台ともオンデマンド（コミュファは 1 セッションのため）。preempt は 2 台とも切る（#1 が戻った瞬間にセッションがぶつからないように）。
- DHCP は範囲を前半（#1）・後半（#2）に分けて、2 台とも配る。
- IX2215 は LACP 非対応なので、スイッチとは静的 LAG。

### VLAN

| VLAN | 名前 | サブネット | 主な用途 | 状態 |
|---|---|---|---|---|
| — | 家族 | 192.168.0.0/24 | 家族用 LAN | 稼働 |
| 10 | 一般 | 192.168.10.0/24 | PC・スマホ・SSID lab | 稼働 |
| 20 | サーバー | 192.168.20.0/24 | DB・Git・VPN・監視・バックアップ | 稼働 |
| 30 | DMZ | 192.168.30.0/24 | proxy01・mc01 | 稼働 |
| 50 | 検証 | 192.168.50.0/24 | テスト VM・SSID test | 稼働 |
| 60 | ゲスト | 192.168.60.0/24 | SSID guest（インターネットだけ） | 予定 |
| 99 | 管理 | 192.168.99.0/24 | Proxmox・スイッチ・AP・IX の実 IP | 稼働 |
| — | Ceph | 192.168.100.0/24 | 10GbE 直結（スイッチ・IX を通らない） | 構築中 |

## Proxmox クラスタ

### ハードウェアの変更

| ノード | 変更 | 状態 |
|---|---|---|
| ① pve-mc | GTX 1660 Ti を外して x16 に 10GbE NIC、Ceph 用 SSD | 構築中 |
| ② pve-app | x16 に 10GbE NIC、Ceph 用 SSD | 構築中 |
| ③ pve-infra | メモリ 16GB → 32GB、x16 に 10GbE NIC（ロープロファイル）、Ceph 用 SSD、NUT サーバー | 構築中 |

- 10GbE NIC：Mellanox ConnectX-4 Lx（2 ポート）×3、SFP+ DAC ×3 で三角形に直結。1 本切れても残りの 2 本で遠回りして通じる（OpenFabric）。
- Ceph 用 SSD：停電保護（PLP）付きの業務用 SATA SSD 480GB ×3（Intel DC S3520 など）。

### Ceph

- 3 台で MON・MGR・OSD を 1 つずつ。プール `ceph-vm` は 3 重（size 3 / min_size 2）、使える容量は約 480GB。
- **Ceph に置くもの**：HA 対象（proxy01・db01・vpn01・mon01・vault01）。ノードが止まっても、別のノードで止まった瞬間のデータのまま起動する。
- **ローカルのまま**：mc01（メモリ 48GB で他のノードに移せないため。②への ZFS レプリケーションで守る）、pbs01（HDD を直接使うため）。

## 監視

```
自宅が丸ごと止まる → relay01 の Uptime Kuma が気づく → Discord
relay01 が止まる   → 自宅の Uptime Kuma が気づく    → Discord
```

| 場所 | 入れるもの |
|---|---|
| mon01 | Prometheus（30日）・Alertmanager（Discord）・Grafana・pve-exporter・snmp_exporter（IX 2台・スイッチ・AP）・blackbox（WAN・IX の実 IP・サービスのポート）・Loki・Oxidized |
| log01 | rsyslog ＋ Alloy（Loki へ送る） |
| relay01 | Uptime Kuma（Tailscale の中からだけ見られる） |
| 各ノード | node_exporter |

アラート：WanDown・RouterDown・NodeDown・ServiceDown・CephNotHealthy（重要）、DiskLow・MemoryHigh・CpuHigh・TempHigh（警告）。

## 停電対策

- APC BR1200S-JP E（2 階のラボ機器だけ。ONU・Aterm は 1 階なので対象外）。
- ③ が NUT サーバー。停電したら ① を 2 分後に止め、② と ③ はバッテリーが減ったらほぼ同時に止める。
  - ② を先に止めると ③ だけになり、Ceph（2 台必要）とクォーラム（2 票必要）が足りなくなって ③ が強制再起動されるため。
- HA の止まり方は `shutdown_policy=freeze`（停電中に VM を移動させない）。

## 作業の順番

1. UPS と NUT
2. ③のメモリ交換
3. 監視基盤（Prometheus など）と相互監視
4. IX2215 #2 の投入と VRRP 化、切替テスト
5. 無線 AP・VLAN60
6. 10GbE NIC と SSD の取り付け、フルメッシュの設定
7. Ceph の構築、HA 対象を Ceph に移す
8. watch-group（回線だけ切れたときの切替）
9. Loki・Oxidized

## 保留

- 10Gbps の回線：ルーター（IX2215）が 1G なので、回線だけ変えても速くならない。やるなら 10G のルーター・スイッチ・NIC が必要。
- k3s（Kubernetes）：① の E コアに 3 台で作る予定。
- RTX1200：友人の RTX1200 と IPsec のサイト間 VPN を試す勉強用に残す。
