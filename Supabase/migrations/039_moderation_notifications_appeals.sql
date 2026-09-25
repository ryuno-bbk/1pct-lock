-- ============================================================
-- 039_moderation_notifications_appeals.sql
-- モデレーション結果の通知 + 異議申し立て (2026-07-20 実機FB #9)
-- ============================================================
-- 背景:
--   投稿/コメントが AI モデレーションで rejected/flagged になっても本人に
--   何も通知されず、異議申し立て手段もなかった (2026-07-20 実機FB #9)。
--
-- 設計判断 (ユーザー確定):
--   - システム生成通知 (モデレーション結果・異議申し立て結果) は「本人が自分自身への
--     通知の送り主になる」(recipient_user_id = actor_user_id) という自己参照方式で
--     実装する。新しい sentinel アカウントは作らない (public.users.id は
--     auth.users(id) への FK 制約があるため、実ユーザー行を伴わないダミーアカウントは
--     正規の Auth フローの外側になり複雑になりすぎる)。
--   - 自己参照は既存の 3 制約と整合する:
--       1. user_notifications.actor_user_id は NOT NULL + FK → 常に有効な user
--       2. fetch_notifications の JOIN public.users u ON u.id = n.actor_user_id は
--          INNER JOIN だが、自分自身の行は必ず存在するので問題なし
--       3. Swift 側 UserNotification.actorUserId は非オプショナル UUID のままデコード可能
--     → user_notifications_no_self CHECK と create_notification() の自己アクション
--       弾きガードだけ、システム系 kind の時に自己参照を許可するよう緩和する。
--   - user_appeals: 投稿者/コメント者が rejected/flagged コンテンツに異議申し立てできる
--     新規テーブル。file_appeal RPC 経由のみで作成 (直接 INSERT 不可)。解決 (承認/却下)
--     は運営が SQL Editor で手動 UPDATE する運用 (user_reports と同じ)。承認時は
--     resolve_user_appeal トリガーが元コンテンツの moderation_status を 'approved' に
--     戻す。
--
-- 現状確認 (このファイル作成前に 014/015/017/018/022/027 を Read して確認済み):
--   - user_notifications.kind の現行許可リスト (022 で 'new_post' 追加が最新):
--       'like', 'follow', 'comment', 'reply', 'comment_like', 'new_post'
--     CHECK 制約名は無名 → Postgres デフォルト命名 user_notifications_kind_check
--     (022 が `DROP CONSTRAINT IF EXISTS user_notifications_kind_check` で明示的に
--     使っている名前そのもの。023〜038 はこの制約に触れていない)
--   - user_notifications_no_self は 014 定義のまま未変更 (015〜038 で DROP/RENAME なし)
--   - create_notification(p_recipient_user_id, p_actor_user_id, p_kind,
--     p_target_post_id DEFAULT NULL, p_target_quote_id DEFAULT NULL,
--     p_target_comment_id DEFAULT NULL, p_preview_text DEFAULT NULL) のシグネチャは
--     014 定義のまま不変 (015 の REVOKE 文が create_notification(uuid, uuid, text,
--     uuid, uuid, uuid, text) という型リストで確認できる。017/022 の呼び出し箇所の
--     引数名とも一致)
--   - user_comments の対象列: post_id (nullable、017 で NOT NULL 解除) / quote_id
--     (nullable、017 で追加)。user_comments_target_xor で常にどちらか一方だけが
--     非NULLになるよう強制されている。owner 列は author_user_id (014 定義のまま)。
--     → notify_on_comment_moderation は NEW.post_id と NEW.quote_id を両方
--     create_notification に渡す (xor 制約により常に一方だけが値を持つので分岐不要)。
--   - user_posts の owner 列は user_id (005 定義のまま)
--   - moderation_verdict の jsonb キーは Supabase/functions/moderate-post/index.ts で
--     safety_reason / ethos_reason と確認済み (層1 rejected 時は safety_reason、
--     層2 flagged 時は ethos_reason を読む)。同 Edge Function は user_posts と
--     user_comments の両方を webhook 対象にしているため、コメント側のモデレーション
--     結果 UPDATE も実際に発生する。
--   - protect_user_posts_moderation / protect_user_comments_moderation (027 定義) は
--     current_user の pg_roles.rolbypassrls を見て bypass 可否を判定する。
--     SECURITY DEFINER 関数は所有者 (postgres, rolbypassrls=true) で実行されるため、
--     resolve_user_appeal 内部の UPDATE はこれらのトリガーを素通りする
--     (delete_my_account 等、既存の SECURITY DEFINER RPC と同じ挙動)。
--
-- 実行順序: 014 (user_notifications/create_notification) と 027 (moderation列/
--   protect trigger) が適用済みの環境が前提。何度実行しても安全 (DROP IF EXISTS →
--   ADD / CREATE OR REPLACE / IF NOT EXISTS パターン)。適用/デプロイはユーザー側で
--   実施 (Supabase Dashboard → SQL Editor)。本ファイル単体では何も自動実行されない。
-- ============================================================

-- ============================================================
-- 1. user_notifications.kind の許可リストにシステム通知系4種を追加
-- ============================================================
-- 現行許可リスト (022 時点): like/follow/comment/reply/comment_like/new_post
-- 制約名は 022 で明示的に確認済みの user_notifications_kind_check (無名CHECKの
-- Postgres デフォルト命名規則どおり)
ALTER TABLE public.user_notifications
    DROP CONSTRAINT IF EXISTS user_notifications_kind_check;

ALTER TABLE public.user_notifications
    ADD CONSTRAINT user_notifications_kind_check CHECK (
        kind IN (
            'like', 'follow', 'comment', 'reply', 'comment_like', 'new_post',
            'content_rejected', 'content_flagged', 'appeal_approved', 'appeal_rejected'
        )
    );

COMMENT ON TABLE public.user_notifications IS
    'アプリ内通知。kind = like/follow/comment/reply/comment_like/new_post (対人通知) '
    '+ content_rejected/content_flagged/appeal_approved/appeal_rejected '
    '(システム通知、recipient_user_id = actor_user_id の自己参照)';

-- ============================================================
-- 2. 自己参照を許可する (システム通知系 kind のみ)
-- ============================================================
-- 014 定義のまま変更されていない制約名 user_notifications_no_self を緩和。
-- recipient=actor の自己参照は content_rejected/content_flagged/appeal_approved/
-- appeal_rejected の 4 kind のみ許可 (それ以外の対人通知は引き続き自分発を禁止)。
ALTER TABLE public.user_notifications
    DROP CONSTRAINT IF EXISTS user_notifications_no_self;

ALTER TABLE public.user_notifications
    ADD CONSTRAINT user_notifications_no_self CHECK (
        recipient_user_id <> actor_user_id
        OR kind IN ('content_rejected', 'content_flagged', 'appeal_approved', 'appeal_rejected')
    );

-- create_notification(): 自己アクション弾きガードにシステム系 kind の例外を追加。
-- シグネチャ・NULL チェック・INSERT 文・ON CONFLICT 句は 014 定義から完全に維持
-- (変更箇所は自己アクション判定の IF 条件のみ)。
CREATE OR REPLACE FUNCTION public.create_notification(
    p_recipient_user_id uuid,
    p_actor_user_id     uuid,
    p_kind              text,
    p_target_post_id    uuid DEFAULT NULL,
    p_target_quote_id   uuid DEFAULT NULL,
    p_target_comment_id uuid DEFAULT NULL,
    p_preview_text      text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF p_recipient_user_id IS NULL OR p_actor_user_id IS NULL THEN
        RETURN;
    END IF;
    IF p_recipient_user_id = p_actor_user_id
       AND p_kind NOT IN ('content_rejected', 'content_flagged', 'appeal_approved', 'appeal_rejected') THEN
        RETURN;  -- 自分発は通知しない (システム通知系 kind は自己参照を許可)
    END IF;
    INSERT INTO public.user_notifications (
        recipient_user_id, actor_user_id, kind,
        target_post_id, target_quote_id, target_comment_id, preview_text
    ) VALUES (
        p_recipient_user_id, p_actor_user_id, p_kind,
        p_target_post_id, p_target_quote_id, p_target_comment_id, p_preview_text
    )
    ON CONFLICT ON CONSTRAINT user_notifications_unique_like DO NOTHING;
END;
$$;
-- REVOKE/GRANT は 015 で PUBLIC/anon/authenticated 全てから REVOKE 済み (内部の
-- SECURITY DEFINER トリガー/RPC からのみ呼ばれる想定)。CREATE OR REPLACE は
-- シグネチャ不変な限り既存の ACL を保持するため、ここでの再設定は不要。

-- ============================================================
-- 3. user_posts モデレーション結果の自動通知
-- ============================================================
CREATE OR REPLACE FUNCTION public.notify_on_post_moderation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_kind   text;
    v_reason text;
BEGIN
    v_kind := CASE NEW.moderation_status WHEN 'rejected' THEN 'content_rejected' ELSE 'content_flagged' END;
    v_reason := CASE NEW.moderation_status
        WHEN 'rejected' THEN NEW.moderation_verdict->>'safety_reason'
        ELSE NEW.moderation_verdict->>'ethos_reason'
    END;
    PERFORM public.create_notification(
        p_recipient_user_id => NEW.user_id,
        p_actor_user_id     => NEW.user_id,
        p_kind              => v_kind,
        p_target_post_id    => NEW.id,
        p_preview_text      => v_reason
    );
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_posts_notify_moderation ON public.user_posts;
CREATE TRIGGER user_posts_notify_moderation
    AFTER UPDATE ON public.user_posts
    FOR EACH ROW
    WHEN (OLD.moderation_status IS DISTINCT FROM NEW.moderation_status AND NEW.moderation_status IN ('rejected', 'flagged'))
    EXECUTE FUNCTION public.notify_on_post_moderation();
-- RETURNS trigger の関数は Postgres が直接呼び出しを拒否するため (トリガーとしてのみ
-- 実行可能)、014/017/022/027 の他の trigger 関数と同様に REVOKE/GRANT は不要。

-- ============================================================
-- 4. user_comments モデレーション結果の自動通知
-- ============================================================
-- user_comments は post_id / quote_id のどちらか一方のみ非NULL
-- (user_comments_target_xor、017 定義)。create_notification は target_post_id /
-- target_quote_id を独立した nullable 引数として受け付けるため、分岐せず
-- NEW.post_id と NEW.quote_id をそのまま渡せば良い (常にどちらか一方だけが値を持つ)。
CREATE OR REPLACE FUNCTION public.notify_on_comment_moderation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_kind   text;
    v_reason text;
BEGIN
    v_kind := CASE NEW.moderation_status WHEN 'rejected' THEN 'content_rejected' ELSE 'content_flagged' END;
    v_reason := CASE NEW.moderation_status
        WHEN 'rejected' THEN NEW.moderation_verdict->>'safety_reason'
        ELSE NEW.moderation_verdict->>'ethos_reason'
    END;
    PERFORM public.create_notification(
        p_recipient_user_id => NEW.author_user_id,
        p_actor_user_id     => NEW.author_user_id,
        p_kind              => v_kind,
        p_target_post_id    => NEW.post_id,
        p_target_quote_id   => NEW.quote_id,
        p_target_comment_id => NEW.id,
        p_preview_text      => v_reason
    );
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_comments_notify_moderation ON public.user_comments;
CREATE TRIGGER user_comments_notify_moderation
    AFTER UPDATE ON public.user_comments
    FOR EACH ROW
    WHEN (OLD.moderation_status IS DISTINCT FROM NEW.moderation_status AND NEW.moderation_status IN ('rejected', 'flagged'))
    EXECUTE FUNCTION public.notify_on_comment_moderation();

-- ============================================================
-- 5. user_appeals テーブル (異議申し立て)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.user_appeals (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id           uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    target_post_id    uuid REFERENCES public.user_posts(id) ON DELETE CASCADE,
    target_comment_id uuid REFERENCES public.user_comments(id) ON DELETE CASCADE,
    reason            text NOT NULL,
    status            text NOT NULL DEFAULT 'pending'
                          CHECK (status IN ('pending', 'approved', 'rejected')),
    resolution_note   text,
    resolved_at       timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT user_appeals_target_xor CHECK (
        (target_post_id IS NOT NULL AND target_comment_id IS NULL) OR
        (target_post_id IS NULL AND target_comment_id IS NOT NULL)
    )
);

COMMENT ON TABLE public.user_appeals IS
    '投稿/コメントのモデレーション結果 (rejected/flagged) に対する異議申し立て。'
    'file_appeal RPC 経由でのみ作成可能。解決 (承認/却下) は運営が SQL Editor で '
    '手動 UPDATE する運用 (user_reports と同じ)';

CREATE UNIQUE INDEX IF NOT EXISTS user_appeals_unique_post
    ON public.user_appeals(target_post_id) WHERE target_post_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS user_appeals_unique_comment
    ON public.user_appeals(target_comment_id) WHERE target_comment_id IS NOT NULL;

ALTER TABLE public.user_appeals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "user_appeals_select_own" ON public.user_appeals;
CREATE POLICY "user_appeals_select_own"
    ON public.user_appeals FOR SELECT
    USING (auth.uid() = user_id);

-- INSERT/UPDATE/DELETE はクライアント直接不可 (ポリシー未定義 = デフォルト拒否)。
-- 作成は file_appeal RPC 経由のみ (SECURITY DEFINER が所有権/ステータスを検証してから
-- INSERT する)。解決 (承認/却下) は運営が SQL Editor で手動 UPDATE する運用
-- (user_reports の status 解決と同じ運用パターン)。

-- ============================================================
-- 6. file_appeal RPC (異議申し立て送信)
-- ============================================================
CREATE OR REPLACE FUNCTION public.file_appeal(
    p_target_post_id    uuid,
    p_target_comment_id uuid,
    p_reason            text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_appeal_id uuid;
    v_owner_id  uuid;
    v_status    text;
BEGIN
    IF (p_target_post_id IS NOT NULL) = (p_target_comment_id IS NOT NULL) THEN
        RAISE EXCEPTION 'exactly one of target_post_id / target_comment_id required';
    END IF;
    IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
        RAISE EXCEPTION 'reason is required';
    END IF;

    IF p_target_post_id IS NOT NULL THEN
        SELECT user_id, moderation_status INTO v_owner_id, v_status
        FROM public.user_posts WHERE id = p_target_post_id;
    ELSE
        SELECT author_user_id, moderation_status INTO v_owner_id, v_status
        FROM public.user_comments WHERE id = p_target_comment_id;
    END IF;

    IF v_owner_id IS NULL THEN
        RAISE EXCEPTION 'target not found';
    END IF;
    IF v_owner_id <> auth.uid() THEN
        RAISE EXCEPTION 'not your content';
    END IF;
    IF v_status NOT IN ('rejected', 'flagged') THEN
        RAISE EXCEPTION 'only rejected/flagged content can be appealed';
    END IF;

    INSERT INTO public.user_appeals (user_id, target_post_id, target_comment_id, reason)
    VALUES (auth.uid(), p_target_post_id, p_target_comment_id, p_reason)
    RETURNING id INTO v_appeal_id;

    RETURN v_appeal_id;
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'already appealed';
END;
$$;

COMMENT ON FUNCTION public.file_appeal(uuid, uuid, text) IS
    '投稿/コメント (post_id / comment_id のどちらか一方) の異議申し立てを送信。'
    '本人所有かつ moderation_status が rejected/flagged の場合のみ受理。1対象1件まで';

-- 015_security_audit.sql #4 の教訓 (「REVOKE FROM anon だけでは関数の暗黙 PUBLIC
-- grant が残るため anon を遮断しきれない」) を踏襲し、PUBLIC も明示的に剥奪する。
REVOKE EXECUTE ON FUNCTION public.file_appeal(uuid, uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.file_appeal(uuid, uuid, text) TO authenticated;

-- ============================================================
-- 7. 異議申し立て解決トリガー (承認時は元コンテンツを復活)
-- ============================================================
CREATE OR REPLACE FUNCTION public.resolve_user_appeal()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NEW.status = 'approved' THEN
        IF NEW.target_post_id IS NOT NULL THEN
            UPDATE public.user_posts
            SET moderation_status = 'approved', moderated_at = now()
            WHERE id = NEW.target_post_id;
        ELSIF NEW.target_comment_id IS NOT NULL THEN
            UPDATE public.user_comments
            SET moderation_status = 'approved', moderated_at = now()
            WHERE id = NEW.target_comment_id;
        END IF;
        PERFORM public.create_notification(
            p_recipient_user_id => NEW.user_id,
            p_actor_user_id     => NEW.user_id,
            p_kind              => 'appeal_approved',
            p_target_post_id    => NEW.target_post_id,
            p_target_comment_id => NEW.target_comment_id
        );
    ELSIF NEW.status = 'rejected' THEN
        PERFORM public.create_notification(
            p_recipient_user_id => NEW.user_id,
            p_actor_user_id     => NEW.user_id,
            p_kind              => 'appeal_rejected',
            p_target_post_id    => NEW.target_post_id,
            p_target_comment_id => NEW.target_comment_id,
            p_preview_text      => NEW.resolution_note
        );
    END IF;
    RETURN NEW;
END;
$$;

-- 補足: この関数は SECURITY DEFINER (postgres 所有) で実行されるため、内部の
-- UPDATE user_posts/user_comments は protect_user_posts_moderation /
-- protect_user_comments_moderation トリガー (027 定義、current_user の
-- rolbypassrls を見て bypass 可否を判定) を自然に通過する。delete_my_account 等の
-- 既存 SECURITY DEFINER RPC と同じ仕組みなので、追加の回避処理は不要。
-- また 'approved' への遷移は user_posts_notify_moderation /
-- user_comments_notify_moderation トリガーの WHEN 句 (rejected/flagged のみ発火)
-- に該当しないため、二重通知やループは発生しない。
DROP TRIGGER IF EXISTS user_appeals_resolve ON public.user_appeals;
CREATE TRIGGER user_appeals_resolve
    AFTER UPDATE ON public.user_appeals
    FOR EACH ROW
    WHEN (OLD.status = 'pending' AND NEW.status <> 'pending')
    EXECUTE FUNCTION public.resolve_user_appeal();

-- ============================================================
-- 8. 動作確認用クエリ (実行不要、コメント)
-- ============================================================
-- モデレーション結果通知の確認 (投稿が flagged/rejected に変わった直後):
--   SELECT * FROM fetch_notifications(20) WHERE kind IN ('content_rejected', 'content_flagged');
-- 異議申し立て送信 (自分の rejected/flagged 投稿に対して):
--   SELECT file_appeal('<post_id>'::uuid, NULL, '誤判定だと思います');
-- 運営側の承認 (SQL Editor):
--   UPDATE user_appeals SET status = 'approved', resolved_at = now() WHERE id = '<appeal_id>';
-- 運営側の却下 (SQL Editor):
--   UPDATE user_appeals SET status = 'rejected', resolution_note = '規約違反のため却下', resolved_at = now()
--   WHERE id = '<appeal_id>';
-- 承認後、対象投稿の moderation_status が 'approved' に戻っていることの確認:
--   SELECT moderation_status FROM user_posts WHERE id = '<post_id>';
-- 承認/却下の通知が届いていることの確認:
--   SELECT * FROM fetch_notifications(20) WHERE kind IN ('appeal_approved', 'appeal_rejected');
