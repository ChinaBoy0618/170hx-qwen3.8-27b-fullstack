# new-api BASELINE

> 上游：QuantumNous/new-api，rc25 世代（0831），非 git 仓库。
> 7 文件全量 overlay，无 diff 可溯；以锚点 sha256 钉版。

## 上游 pin

- go.mod module: `github.com/QuantumNous/new-api`
- go 版本: `1.25.1`
- 构建镜像: `golang:1.26.1-alpine@sha256:2389ebfa5b7f43eeafbd6be0c3700cc46690ef842ad962f6c5bd6be49ed82039`
- 产物镜像: `new-api:fixtoolidx-0831-full` (sha256:`aab1b94f18fa7110b3e7ba7165354479891e4cedf10821cdfcdc62bb51a1fd74`)

## 7 文件 overlay sha256 锚点

| 文件 | sha256 |
|---|---|
| `overlay/setting/sensitive.go` | `bd24fcde3754e0d943de2f75b7c2e117752f56983c5bca2acb0e5c40f0b0b333` |
| `overlay/controller/relay.go` | `c05c3fb9407859cc8b6d556cd9d090f4455240adf701d8a7d461a0dbda6d0a3d` |
| `overlay/model/option.go` | `f8328ea15d5bb0943d090fe0aad3b4ee4615092d67f9057aa1659e8284532d44` |
| `overlay/relay/common/relay_info.go` | `b602e507ccbff72254a2049029da0baec31917c2ef3bbd2297b3de64f1ebcf15` |
| `overlay/relay/channel/claude/relay-claude.go` | `bd3ad68dd9837ecae845846ebfea1ea6e772cbe055e5ed40b4fcf619be94902d` |
| `overlay/relay/channel/openai/relay-openai.go` | `41451d9df6e1fa5bbaceec6b956a89bd2ec61204b707bcb3ff9fa097f15857bc` |
| `overlay/service/log_info_generate.go` | `fdd347ec3f020f905b428ff14f47933584e491e1a31da085c28cd5feedfa5566` |

## 未改锚点（上游原文件，用于验证 overlay 未污染基线）

> 构建前 `go mod download` 后，以下文件的 sha256 应与上游 rc25/0831 一致。
> 任何不一致说明 overlay 意外覆盖了基线文件。

（首次构建时回填）
