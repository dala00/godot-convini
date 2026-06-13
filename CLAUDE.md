# CLAUDE.md

このプロジェクト **convini（コンビニ レジ打ちゲーム）** は、[Claude Code](https://claude.com/claude-code)（Anthropic）との対話で作成されました。ゲームロジックのGDScript、Blenderによる3Dモデル、効果音のPCM合成まで、すべてAIと人の対話で組み上げています。

## プロジェクト概要

- エンジン: **Godot 4.6**（GL Compatibility レンダラ）／2Dゲーム
- ジャンル: コンビニのレジ打ち＆袋詰めパズル
- ルール詳細は [README.md](README.md) を参照

## 構成

- `scenes/main.tscn` … 薄い土台シーン（`game_manager.gd` を持つだけ）
- `scripts/game_manager.gd` … ゲーム全体。レイアウト・干渉判定・客/難易度・スコア・ゲームオーバー演出・効果音・BGM
- `scripts/product.gd` … 商品1個（描画・90度回転・バーコード）
- `sprites/` … 商品スプライト（Blenderでローポリ作成→真上から正射影レンダリングした透過PNG）
- `sounds/` … BGM（mp3）
- `ai_tools/cap.ps1` … 実行中ウィンドウを `PrintWindow` でキャプチャする目視ループ用スクリプト（`.gdignore` 配下）

## 設計方針（このリポジトリの流儀）

- **コード生成中心・薄い tscn**: エンティティ（商品）やUIは `.tscn` を手書きせず、`_ready` でコードから生成・描画する。`.tscn` は静的な土台だけに留める。
- **干渉**: カゴ・袋・商品はすべて当たり判定を持つ。マウス追従中の商品は軸ごとのスイープAABBで連続衝突判定し、壁や他商品にぶつかると止まる（`DETACH_ON_HIT` 定数で「ぶつかったら落ちる」方式に切替可）。
- **袋詰め**: 6×5グリッドにマス吸着、占有配列 `occ` で重なり判定。回転は `grid_w/grid_h` の入れ替え＋スプライトの90度回転で表現。
- **効果音**: 音声アセットを使わず、`_make_sfx()` でサイン/矩形/三角/ノイズ波形＋エンベロープを合成して `AudioStreamWAV` を生成。
- **日本語フォント**: `SystemFont`（Meiryo等）を `draw_string` で使用。

## 開発ワークフロー

1. コードを編集
2. godot-mcp の `run_project` / `get_debug_output` で実行＆エラー確認
3. `ai_tools/cap.ps1` でゲーム画面をキャプチャして目視
4. 修正 → 2に戻る（「変更 → 実行 → 目視 → 修正」の高速ループ）

Blenderモデルは Blender MCP の `execute_blender_code` で `bpy` を直接操作して生成し、一時カメラ（正射影・真下）で透過PNGに焼いて `sprites/` へ出力している。

## 注意

- `.claude/settings.json` … プロジェクト共有の許可設定（個人パスは含めない）
- `.claude/settings.local.json` … 個人環境向け（gitignore対象。絶対パスを含む許可はこちら）
- 個人PCの絶対パスはコミット対象ファイルに書かない。
