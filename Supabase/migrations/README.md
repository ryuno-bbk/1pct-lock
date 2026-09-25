> **Setup instructions are in the root `README.md` (section "Backend (Supabase)").**
> Run `000_baseline_quotes_authors.sql` first, then `001` to `083` in order.
> The Japanese notes below are older and only cover the first migrations.

# Supabase Migrations

S2 以降の実装フェーズで、Supabase Dashboard → SQL Editor に**順番に貼り付けて実行する**マイグレーションファイル群。

## 実行順序（厳守）

1. `001_a_auth.sql` — users テーブル + Apple Sign-In 連動 trigger
2. `002_a_user_id.sql` — user_likes / user_follows を device_id → user_id ベースに DROP & CREATE
3. `003_a_rls_rpc.sql` — 全 RLS 書き直し + 旧 RPC 削除 + 新 toggle_quote_like
4. `004_b_official.sql` — authors.is_official 列追加
5. `005_b_user_posts.sql` — user_posts テーブル + toggle_post_like RPC
6. `006_b_moderation.sql` — user_reports / user_blocks + ブロック時 unfollow trigger
7. `007_b_block_sessions.sql` — 累計ロック時間テーブル

## Phase 対応表

| Phase | ファイル | 内容 |
|---|---|---|
| A-1 | 001 | Apple Sign-In 認証 |
| A-2 | 002 | user_id 化 |
| A-3 | 003 | RLS + 新 RPC |
| A-4 | （SQL なし、コード変更のみ）| Quotes.json 再生成 |
| B-1 | 004 | 公式マーク |
| B-2 | 005 | UGC |
| B-3 | 006 | モデレーション |
| B-5 | 007 | 累計時間 |

## 実行前の注意

- 各ファイルは Supabase Dashboard → SQL Editor で 1 つずつ実行
- 002 は `DROP TABLE` を含む → 実行前に Supabase Dashboard で「現在のデータをエクスポートしたか」確認（リリース前なので無視可だが念のため）
- 003 で旧 RPC `increment_like_count` / `decrement_like_count` を削除 → 同時にクライアント側 `LikeService` も新 API に置換しないとアプリのいいねが壊れる（S2 実装時の作業）

## ロールバック

各ファイルは原則「DROP IF EXISTS → CREATE」「ADD COLUMN IF NOT EXISTS」「ON CONFLICT DO NOTHING」で冪等化。再実行可能。
ただし `002_a_user_id.sql` は DROP TABLE を含むので、本番運用後の再実行は破壊的。
