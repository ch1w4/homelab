# Home Lab Infrastructure

個人で構築・運用しているオンプレミスホームラボの構成管理リポジトリです。
物理サーバー2台によるProxmox VEクラスタを中核に、用途別VMをDocker Composeで管理しています。

---

## アーキテクチャ概要

```
[Internet]
    |
    | Commufa Hikari (光回線)
    v
[NEC IX2215]  -- ルーター / ファイアウォール
    |
    | 802.1Qトランク
    v
[Allied Telesis スイッチ]
    └── VLAN20: 192.168.20.0/24  (サーバー・管理セグメント)
          ├── 20.13  nginx    Nginx Proxy Manager
          ├── 20.16  vpn      Tailscale (LXCコンテナ)
          ├── 20.24  dbot     Discord Bot
          ├── 20.25  mcsv     Minecraft Server
          ├── 20.26  web1     WordPress 個人ブログ
          ├── 20.27  pal      Palworld Server
          ├── 20.28  u22      U-22プログラミングコンテスト作品
          ├── 20.29  pckyo    予約管理アプリ（パソコン教室向け + LINE Bot）
          └── 20.30  ih       進級制作品
```

### 外部アクセス構成

```
[外部ユーザー]
    |
    v
[Cloudflare DNS] --- サブドメイン管理
    |
    v
[DDNS: chiwasv.f5.si]
    |
    v
[NEC IX2215] -- ポートフォワード --> 20.13 Nginx Proxy Manager
                                          ├── web1.example.com --> 20.26
                                          └── app.example.com  --> 20.29

[管理アクセス] -- Tailscale VPN (20.16) 経由のみ許可
```

---

## ハードウェア構成

| ホスト名 | 機種 | 役割 |
|----------|------|------|
| pve-node1 | HPE ProLiant DL380 Gen9 | Primary Node |
| pve-node2 | HPE ProLiant DL160 Gen9 | Secondary Node |

- Proxmox VE クラスタ（2ノード）
- VMバックアップはProxmox Backup Server (PBS) で管理

---

## ネットワーク設計

### セグメント構成

VLAN20（192.168.20.0/24）にサーバーを集約している。
当初はサーバーとクライアントをVLAN分離する構成も検討したが、現状は管理の簡素化を優先して単一セグメントで運用している。

| 項目 | 内容 |
|------|------|
| セグメント | 192.168.20.0/24 |
| ゲートウェイ | 192.168.20.1 (IX2215) |
| 外部公開 | Nginx Proxy Manager経由 (443のみ) |
| 管理アクセス | Tailscale VPN (20.16) 経由のみ |
| DNS | Cloudflare + DDNS (chiwasv.f5.si) |

### ルーター（NEC IX2215）

IX2215をエッジルーターとして使用し、以下を設定している。

- PPPoEによるWAN接続
- 802.1Qトランクポートでスイッチと接続
- ポートフォワード: 外部443番ポート → 20.13（Nginx Proxy Manager）
- ACL: 外部からの直接SSHを全ポートで遮断

### 管理アクセスの方針

外部からの管理操作はすべてTailscale VPN（20.16）経由に統一している。
SSHポートをインターネットに公開しないことで、ブルートフォース攻撃やポートスキャンのリスクを排除している。
Tailscaleのコントロールプレーンを利用することで、鍵配布や証明書管理のコストを最小化している。

### 外部公開とDNS

グローバルIPが変動するため、DDNSサービス（chiwasv.f5.si）でIPを動的に更新している。
CloudflareのCNAMEでサブドメインをDDNSホスト名に向け、証明書はNginx Proxy Manager上でLet's Encryptから自動取得している。

---

## VM・サービス一覧

| IP | ホスト名 | 種別 | サービス | 説明 |
|----|----------|------|---------|------|
| 20.13 | nginx | VM | Nginx Proxy Manager | リバースプロキシ / SSL終端 |
| 20.16 | vpn | LXC | Tailscale | VPNゲートウェイ |
| 20.24 | dbot | VM | Discord Bot | 自作通知・管理Bot |
| 20.25 | mcsv | VM | Minecraft Server | Velocityプロキシ + 複数ワールド |
| 20.26 | web1 | VM | WordPress | 個人ブログ |
| 20.27 | pal | VM | Palworld Server | ゲームサーバー |
| 20.28 | u22 | VM | U-22作品 | U-22プログラミングコンテスト応募作品 |
| 20.29 | pckyo | VM | 予約管理アプリ | パソコン教室向け予約管理 + LINE Bot連携 (Next.js 14 / PostgreSQL) |
| 20.30 | ih | VM | 進級制作品 | 学校課題用VM |

---

## セキュリティ方針

- 管理SSH: Tailscale VPN経由のみ（外部直接SSHは閉鎖）
- 公開ポート: 443のみ（Nginx Proxy Manager経由）
- シークレット: .envを.gitignoreに追加、リポジトリには含めない
- IPアドレス: このREADMEではプライベートIPのみ記載

---

## 学んだこと・今後の展望

学んだこと
- Proxmoxクラスタ構築・VMとLXCコンテナの使い分け
- IX2215でのVLAN設計・ACL設定・ポートフォワード
- Docker Composeによる複数サービスのライフサイクル管理
- LXCコンテナへのTailscaleインストール（TUN/TAP対応）

今後やりたいこと
- Ansibleによるサーバー初期セットアップの自動化
- GrafanaダッシュボードのIaC化
- OSPFルーティングの実機検証
