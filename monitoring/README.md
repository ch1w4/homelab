# 監視

mon01（LXC 2030・③ pve-infra・Ceph＋HA）で Docker Compose で動かしています。外からは Oracle Cloud の mon-ext01 が見張ります。

| 部品 | 役割 |
|---|---|
| Prometheus 3 | 数値を集める（30 秒ごと） |
| node_exporter | 3 ノードと mc01 の CPU・メモリ・温度・ディスク |
| pve-exporter | Proxmox の VM/LXC の状態 |
| blackbox | WAN（外への ping）・IX 2台とスイッチの応答・サービスのポート |
| snmp_exporter | IX 2台の VRRP 状態（VRRP-MIB の vrrpOperState：3=Master、2=Backup）と回線の通信量 |
| Alertmanager | Discord に通知（復旧の通知あり） |
| Grafana | 日本語のダッシュボード（[grafana/chiwa-lab-home.json](grafana/chiwa-lab-home.json)） |
| Uptime Kuma | 利用者と同じ URL を外側から確認。mon-ext01 の Push も受ける |
| 状態画面（nginx） | 自作の日本語ページ（[status/](status/)）。Prometheus の読み取り用 API 2 つだけを中継する |

## アラート

| 名前 | 条件 |
|---|---|
| WanDown | 自宅から外に届かない |
| RouterDown | IX・スイッチの実 IP が 1 分応答しない |
| NodeDown | ノードの node_exporter が応答しない |
| ServiceDown | サービスのポートが 2 分開かない |
| VrrpFailover | #2 が Master になっている（30 秒続いたら）。11/16 の試験で「#1 に聞く」作りの穴が見つかり、#2 側で判定するよう修正 |
| VrrpSplitBrain | 2 台とも Master |
| DiskLow / MemoryHigh / CpuHigh / TempHigh | 使用率・温度のしきい値 |

## 状態画面と障害試験

- [status/index.html](status/index.html)：いまの状態・グラフ・24 時間の記録・障害試験の結果を表示する 1 ファイルのページ
- [status/nginx.conf](status/nginx.conf)：`/api/v1/query` と `/api/v1/query_range` だけを Prometheus に中継し、ほかの API は 403
- [status/failtest.sh](status/failtest.sh)：障害試験の計測スクリプト（0.5 秒ごとに ping / TCP を確認し、Alertmanager の通知も見る）
- [status/tests.json](status/tests.json)：試験の方法と結果。まとめは [docs/failover-tests.md](../docs/failover-tests.md)

```
./failtest.sh ping:1.1.1.1 VrrpFailover        # Enter の瞬間を T0 として障害を起こす
./failtest.sh tcp:192.168.20.45:3000 ServiceDown
./failtest.sh baseline ping:1.1.1.1 600        # 正常時の基準
```

Discord の Webhook・Proxmox の API トークンなどの秘密は `.env`・`alertmanager.yml`（chmod 600）に置き、このリポジトリには含めません。
